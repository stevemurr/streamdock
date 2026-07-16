import Darwin
import Foundation

public enum WebControlServerError: LocalizedError {
    case invalidPort(Int)
    case systemCall(String, Int32)

    public var errorDescription: String? {
        switch self {
        case let .invalidPort(port):
            "web server port must be between 1 and 65535 (got \(port))"
        case let .systemCall(name, code):
            "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

public struct WebDeckKey: Codable, Equatable, Sendable {
    public var position: Int
    public var label: String
    public var icon: String?
    public var color: String
    public var isActive: Bool
    public var hasAction: Bool

    public init(
        position: Int,
        label: String,
        icon: String? = nil,
        color: String,
        isActive: Bool = false,
        hasAction: Bool = true
    ) {
        self.position = position
        self.label = label
        self.icon = icon
        self.color = color
        self.isActive = isActive
        self.hasAction = hasAction
    }
}

public struct WebDeckPage: Codable, Equatable, Sendable {
    public var name: String
    public var keys: [WebDeckKey]

    public init(name: String, keys: [WebDeckKey]) {
        self.name = name
        self.keys = keys
    }
}

public struct WebDeckState: Codable, Equatable, Sendable {
    public var activePage: String
    public var pages: [WebDeckPage]

    public init(activePage: String, pages: [WebDeckPage]) {
        self.activePage = activePage
        self.pages = pages
    }
}

private struct WebPressPayload: Codable {
    var position: Int
    var page: String?
}

private struct WebPagePayload: Codable {
    var page: String
}

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

private struct HTTPResponse {
    var status: Int
    var reason: String
    var contentType: String
    var body: Data

    static func text(_ status: Int, _ reason: String, _ text: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            reason: reason,
            contentType: "text/plain; charset=utf-8",
            body: Data(text.utf8)
        )
    }
}

/// A small, dependency-free HTTP server for the phone-sized deck interface.
/// It deliberately exposes only deck state, key presses, and page switching.
public final class WebControlServer: @unchecked Sendable {
    public typealias StateProvider = @Sendable () async -> WebDeckState
    public typealias ActionHandler = @Sendable (ControlRequest) async -> ControlResponse

    private let stateProvider: StateProvider
    private let actionHandler: ActionHandler
    private let lock = NSLock()
    private var listenDescriptor: Int32 = -1
    private var stopRequested = false
    private var loopFinished: DispatchSemaphore?
    public private(set) var boundPort: UInt16 = 0

    public init(
        stateProvider: @escaping StateProvider,
        actionHandler: @escaping ActionHandler
    ) {
        self.stateProvider = stateProvider
        self.actionHandler = actionHandler
    }

    /// Reachable IPv4 addresses, preferring normal Ethernet/Wi-Fi interfaces
    /// over VPNs and virtual adapters. Useful for showing a phone-ready URL.
    public static func localIPv4Addresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var found: [(priority: Int, name: String, address: String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current?.pointee {
            defer { current = interface.ifa_next }
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == sa_family_t(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            let priority = name == "en0" ? 0 : (name.hasPrefix("en") ? 1 : 2)
            let address = String(
                decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            found.append((priority, name, address))
        }
        var seen: Set<String> = []
        return found.sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }
            .map(\.address)
            .filter { seen.insert($0).inserted }
    }

    deinit { stop() }

    /// Binds to every IPv4 interface so another device on the same LAN can
    /// reach the page. Passing port 0 asks the OS for an ephemeral test port.
    @discardableResult
    public func start(port: Int) throws -> UInt16 {
        guard (0...65535).contains(port) else { throw WebControlServerError.invalidPort(port) }
        stop()

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WebControlServerError.systemCall("socket", errno) }
        var started = false
        defer { if !started { close(descriptor) } }

        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw WebControlServerError.systemCall("bind", errno) }
        guard Darwin.listen(descriptor, 16) == 0 else {
            throw WebControlServerError.systemCall("listen", errno)
        }

        var actual = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &actualLength)
            }
        }
        guard nameResult == 0 else { throw WebControlServerError.systemCall("getsockname", errno) }

        let finished = DispatchSemaphore(value: 0)
        lock.lock()
        listenDescriptor = descriptor
        stopRequested = false
        loopFinished = finished
        boundPort = UInt16(bigEndian: actual.sin_port)
        lock.unlock()
        started = true

        let thread = Thread { [weak self] in
            self?.acceptLoop(descriptor: descriptor)
            finished.signal()
        }
        thread.name = "streamdock-web-control-server"
        thread.start()
        return boundPort
    }

    public func stop() {
        lock.lock()
        let descriptor = listenDescriptor
        let finished = loopFinished
        stopRequested = true
        listenDescriptor = -1
        loopFinished = nil
        boundPort = 0
        lock.unlock()
        guard descriptor >= 0 else { return }
        _ = finished?.wait(timeout: .now() + 2)
        close(descriptor)
    }

    private func acceptLoop(descriptor: Int32) {
        while true {
            lock.lock()
            let stopping = stopRequested
            lock.unlock()
            if stopping { return }

            var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pending, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }

            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            let stateProvider = self.stateProvider
            let actionHandler = self.actionHandler
            let connection = Thread {
                Self.handleConnection(
                    descriptor: client,
                    stateProvider: stateProvider,
                    actionHandler: actionHandler
                )
            }
            connection.name = "streamdock-web-control-connection"
            connection.start()
        }
    }

    private static func handleConnection(
        descriptor: Int32,
        stateProvider: @escaping StateProvider,
        actionHandler: @escaping ActionHandler
    ) {
        defer { close(descriptor) }
        ControlSocket.configure(descriptor: descriptor)
        let response: HTTPResponse
        do {
            let request = try readRequest(from: descriptor)
            response = route(request, stateProvider: stateProvider, actionHandler: actionHandler)
        } catch {
            response = .text(400, "Bad Request", "Bad request")
        }
        try? ControlSocket.sendAll(encode(response), to: descriptor)
    }

    private static func route(
        _ request: HTTPRequest,
        stateProvider: @escaping StateProvider,
        actionHandler: @escaping ActionHandler
    ) -> HTTPResponse {
        if request.method == "GET", request.path == "/" {
            return HTTPResponse(
                status: 200,
                reason: "OK",
                contentType: "text/html; charset=utf-8",
                body: Data(interfaceHTML.utf8)
            )
        }
        if request.method == "GET", request.path == "/api/state" {
            let state: WebDeckState = awaitValue { await stateProvider() }
            return jsonResponse(state)
        }
        if request.method == "POST", request.path == "/api/press" {
            guard acceptsJSON(request), hasSameOrigin(request) else {
                return .text(403, "Forbidden", "Same-origin JSON requests only")
            }
            guard let payload = try? JSONDecoder().decode(WebPressPayload.self, from: request.body),
                  (0..<18).contains(payload.position) else {
                return .text(400, "Bad Request", "Invalid key position")
            }
            let result: ControlResponse = awaitValue {
                await actionHandler(.init(
                    command: ControlCommand.press,
                    key: String(payload.position),
                    page: payload.page,
                    depth: 0
                ))
            }
            return jsonResponse(result, status: result.ok ? 200 : 400)
        }
        if request.method == "POST", request.path == "/api/page" {
            guard acceptsJSON(request), hasSameOrigin(request) else {
                return .text(403, "Forbidden", "Same-origin JSON requests only")
            }
            guard let payload = try? JSONDecoder().decode(WebPagePayload.self, from: request.body),
                  !payload.page.isEmpty, payload.page.utf8.count <= 256 else {
                return .text(400, "Bad Request", "Invalid page")
            }
            let result: ControlResponse = awaitValue {
                await actionHandler(.init(command: ControlCommand.switchPage, page: payload.page, depth: 0))
            }
            return jsonResponse(result, status: result.ok ? 200 : 400)
        }
        return .text(404, "Not Found", "Not found")
    }

    private static func acceptsJSON(_ request: HTTPRequest) -> Bool {
        request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true
    }

    /// Browsers attach Origin to cross-site POSTs. Refuse those before they can
    /// trigger an action; native clients without Origin remain usable.
    private static func hasSameOrigin(_ request: HTTPRequest) -> Bool {
        guard let origin = request.headers["origin"], !origin.isEmpty else { return true }
        guard let host = request.headers["host"], let url = URL(string: origin),
              let originHost = url.host else { return false }
        let requestParts = host.split(separator: ":", maxSplits: 1).map(String.init)
        guard requestParts.first?.caseInsensitiveCompare(originHost) == .orderedSame else { return false }
        let requestPort = requestParts.count == 2 ? Int(requestParts[1]) : 80
        return (url.port ?? (url.scheme == "https" ? 443 : 80)) == requestPort
    }

    private static func awaitValue<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) -> Value {
        let box = SendableValueBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.set(await operation())
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()!
    }

    private static func readRequest(from descriptor: Int32) throws -> HTTPRequest {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Data.Index?

        while data.count <= 65536, headerEnd == nil {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { throw WebControlServerError.systemCall("recv", errno) }
            data.append(contentsOf: buffer[0..<count])
            headerEnd = data.range(of: separator)?.upperBound
        }
        guard let headerEnd, headerEnd <= 32768 else {
            throw WebControlServerError.systemCall("request headers", E2BIG)
        }

        let headerData = data[..<(headerEnd - separator.count)]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw WebControlServerError.systemCall("request encoding", EINVAL)
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw WebControlServerError.systemCall("request line", EINVAL) }
        let requestParts = first.split(separator: " ")
        guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/1.") else {
            throw WebControlServerError.systemCall("request line", EINVAL)
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...65536).contains(contentLength) else {
            throw WebControlServerError.systemCall("request body", E2BIG)
        }
        while data.count - headerEnd < contentLength {
            let count = recv(descriptor, &buffer, min(buffer.count, contentLength - (data.count - headerEnd)), 0)
            guard count > 0 else { throw WebControlServerError.systemCall("recv", errno) }
            data.append(contentsOf: buffer[0..<count])
        }
        let path = String(requestParts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return HTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: path,
            headers: headers,
            body: data.subdata(in: headerEnd..<(headerEnd + contentLength))
        )
    }

    private static func jsonResponse<Value: Encodable>(_ value: Value, status: Int = 200) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            reason: status == 200 ? "OK" : "Bad Request",
            contentType: "application/json; charset=utf-8",
            body: body
        )
    }

    private static func encode(_ response: HTTPResponse) -> Data {
        let headers = """
        HTTP/1.1 \(response.status) \(response.reason)\r
        Content-Type: \(response.contentType)\r
        Content-Length: \(response.body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:\r
        Referrer-Policy: no-referrer\r
        X-Content-Type-Options: nosniff\r
        X-Frame-Options: DENY\r
        \r

        """
        var data = Data(headers.utf8)
        data.append(response.body)
        return data
    }
}

private final class SendableValueBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private let interfaceHTML = #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <meta name="theme-color" content="#11151b">
  <title>StreamDock</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    body { margin: 0; min-height: 100vh; background: #11151b; color: #f5f7fa; display: grid; place-items: center; }
    main { width: min(100%, 820px); padding: max(18px, env(safe-area-inset-top)) max(14px, env(safe-area-inset-right)) max(18px, env(safe-area-inset-bottom)) max(14px, env(safe-area-inset-left)); }
    nav { display: flex; gap: 8px; overflow-x: auto; padding: 2px 2px 14px; scrollbar-width: none; }
    nav::-webkit-scrollbar { display: none; }
    .page { flex: 0 0 auto; border: 1px solid #343b46; border-radius: 999px; padding: 9px 15px; color: #b9c0cb; background: #1b2028; font: inherit; font-weight: 600; }
    .page.active { color: white; background: #3478f6; border-color: #3478f6; }
    .deck { display: grid; grid-template-columns: repeat(5, minmax(48px, 1fr)); gap: clamp(7px, 2vw, 14px); padding: clamp(10px, 3vw, 22px); border-radius: 25px; background: #090b0e; box-shadow: 0 18px 60px #0008; }
    .key { position: relative; aspect-ratio: 1; min-width: 0; border: 0; border-radius: clamp(10px, 2.6vw, 17px); color: white; padding: 8px 4px; overflow: hidden; box-shadow: inset 0 1px #ffffff28, 0 5px 12px #0008; font: inherit; touch-action: manipulation; transition: transform .08s ease, filter .08s ease; }
    .key:active:not(:disabled) { transform: scale(.93); filter: brightness(1.18); }
    .key:disabled { opacity: .18; box-shadow: inset 0 0 0 1px #ffffff18; }
    .icon { display: block; font-size: clamp(18px, 5.5vw, 34px); line-height: 1.1; }
    .label { display: block; margin-top: 5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: clamp(10px, 2.7vw, 14px); font-weight: 700; text-shadow: 0 1px 2px #000a; }
    .key.active::after { content: ""; position: absolute; inset: 4px; border: 3px solid #48df75; border-radius: inherit; }
    #message { min-height: 32px; padding: 12px 4px 0; color: #aab2be; text-align: center; font-size: 13px; }
    #message.error { color: #ff756f; }
  </style>
</head>
<body>
<main>
  <nav id="pages" aria-label="Pages"></nav>
  <section class="deck" id="deck" aria-label="StreamDock buttons"></section>
  <div id="message" role="status" aria-live="polite"></div>
</main>
<script>
  const pages = document.querySelector('#pages');
  const deck = document.querySelector('#deck');
  const message = document.querySelector('#message');
  let current;
  const icons = {play:'▶', monitor:'▣', gear:'⚙', lock:'🔒', moon:'☾', plus:'＋', minus:'−', power:'⏻', refresh:'↻', sun:'☀', brightness:'☀', cycle:'↻'};

  async function request(path, body) {
    const response = await fetch(path, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)});
    const data = await response.json().catch(() => ({error:'Request failed'}));
    if (!response.ok || !data.ok) throw new Error(data.error || 'Request failed');
    return data;
  }

  async function load(quiet = false) {
    try {
      const response = await fetch('/api/state', {cache:'no-store'});
      if (!response.ok) throw new Error('Could not load buttons');
      current = await response.json();
      render();
      if (!quiet) show('Ready');
    } catch (error) { show(error.message, true); }
  }

  function render() {
    pages.replaceChildren();
    current.pages.forEach(page => {
      const button = document.createElement('button');
      button.className = 'page' + (page.name === current.activePage ? ' active' : '');
      button.textContent = page.name;
      button.onclick = async () => {
        try { const result = await request('/api/page', {page:page.name}); show(result.detail || 'Page changed'); await load(true); }
        catch (error) { show(error.message, true); }
      };
      pages.append(button);
    });

    deck.replaceChildren();
    const page = current.pages.find(item => item.name === current.activePage) || current.pages[0];
    const byPosition = new Map((page?.keys || []).map(key => [key.position, key]));
    for (let position = 0; position < 15; position++) {
      const key = byPosition.get(position);
      const button = document.createElement('button');
      button.className = 'key' + (key?.isActive ? ' active' : '');
      button.disabled = !key || !key.hasAction;
      button.style.background = key?.color || '#20242b';
      button.setAttribute('aria-label', key?.label || `Unassigned key ${position + 1}`);
      if (key) {
        const icon = document.createElement('span'); icon.className = 'icon'; icon.textContent = icons[key.icon] || '●';
        const label = document.createElement('span'); label.className = 'label'; label.textContent = key.label || `Key ${position + 1}`;
        button.append(icon, label);
        button.onclick = async () => {
          button.disabled = true;
          try { const result = await request('/api/press', {position, page:page.name}); show(result.detail || 'Pressed'); await load(true); }
          catch (error) { show(error.message, true); }
          finally { button.disabled = false; }
        };
      }
      deck.append(button);
    }
  }

  function show(text, error = false) { message.textContent = text; message.className = error ? 'error' : ''; }
  load();
  setInterval(() => load(true), 2000);
</script>
</body>
</html>
"""#
