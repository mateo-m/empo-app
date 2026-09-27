// Runs in the game page before the game's own scripts.
//
// RPG Maker MV and MZ games ship for NW.js, a desktop browser with
// Node.js inside. The engine checks for `require` and `process` to know
// it runs there, and then keeps its saves as files next to the game.
// This script gives the page those names, so the saves go to the game
// folder here too. The fs calls become synchronous requests to the
// core's file server (MvmzFileServer.m), because the engine reads and
// writes saves without waiting.
//
// It also answers the calls that mvmz_app_bridge.m makes through
// window.__mvmz.
(() => {
    "use strict";

    const settings = window.__mvmzSettings;
    const post = (message) => window.webkit.messageHandlers.mvmz.postMessage(message);
    const origin = location.protocol + "//" + location.host;

    // MARK: path

    const normalize = (p) => {
        const parts = [];
        for (const part of p.split("/")) {
            if (part === "..") parts.pop();
            else if (part && part !== ".") parts.push(part);
        }
        const tail = p.endsWith("/") && parts.length ? "/" : "";
        return (p.startsWith("/") ? "/" : "") + parts.join("/") + tail || ".";
    };
    const path = {
        sep: "/",
        delimiter: ":",
        normalize,
        join: (...parts) => normalize(parts.filter(Boolean).join("/")),
        resolve: (...parts) => {
            let out = process.cwd();
            for (const part of parts) out = part.startsWith("/") ? part : out + "/" + part;
            return normalize(out).replace(/(.)\/$/, "$1");
        },
        isAbsolute: (p) => p.startsWith("/"),
        dirname: (p) => {
            const trimmed = p.replace(/\/+$/, "");
            const i = trimmed.lastIndexOf("/");
            return i < 0 ? "." : i === 0 ? "/" : trimmed.slice(0, i);
        },
        basename: (p, ext) => {
            const base = p.replace(/\/+$/, "").split("/").pop();
            return ext && base.endsWith(ext) ? base.slice(0, -ext.length) : base;
        },
        extname: (p) => {
            const base = path.basename(p);
            const i = base.lastIndexOf(".");
            return i > 0 ? base.slice(i) : "";
        },
    };
    path.posix = path;

    // MARK: fs

    // "/" is the game folder.
    const urlFor = (p) =>
        origin + path.resolve(String(p)).split("/").map(encodeURIComponent).join("/");

    const send = (method, p, body, binary) => {
        const xhr = new XMLHttpRequest();
        xhr.open(method, urlFor(p), false);
        if (binary) xhr.overrideMimeType("text/plain; charset=x-user-defined");
        xhr.send(body);
        return xhr;
    };

    const fail = (xhr, op, p) => {
        const code = xhr.status === 404 ? "ENOENT" : "EIO";
        const error = new Error(`${code}: ${op} '${p}' (${xhr.status} ${xhr.responseText})`);
        error.code = code;
        throw error;
    };

    const ok = (xhr, op, p) => {
        if (xhr.status >= 300) fail(xhr, op, p);
        return xhr;
    };

    const stat = (p) => {
        const xhr = ok(send("HEAD", p), "stat", p);
        const directory = xhr.getResponseHeader("X-Mvmz-Kind") === "directory";
        const mtime = new Date(Number(xhr.getResponseHeader("X-Mvmz-Mtime")) || 0);
        return {
            size: Number(xhr.getResponseHeader("Content-Length")) || 0,
            mtime,
            mtimeMs: mtime.getTime(),
            isFile: () => !directory,
            isDirectory: () => directory,
            isSymbolicLink: () => false,
        };
    };

    const fs = {
        existsSync: (p) => send("HEAD", p).status === 200,
        statSync: stat,
        lstatSync: stat,
        readFileSync: (p, options) => {
            const encoding = typeof options === "string" ? options : options && options.encoding;
            const xhr = ok(send("GET", p, null, !encoding), "open", p);
            if (encoding) return xhr.responseText;
            const text = xhr.responseText;
            const bytes = new Uint8Array(text.length);
            for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
            return bytes;
        },
        writeFileSync: (p, data) => void ok(send("PUT", p, data), "open", p),
        unlinkSync: (p) => void ok(send("DELETE", p), "unlink", p),
        rmdirSync: (p) => void ok(send("DELETE", p), "rmdir", p),
        mkdirSync: (p) => void ok(send("MKCOL", p), "mkdir", p),
        readdirSync: (p) => JSON.parse(ok(send("GET", p), "scandir", p).responseText),
        renameSync: (from, to) => {
            const xhr = new XMLHttpRequest();
            xhr.open("MOVE", urlFor(from), false);
            xhr.setRequestHeader("Destination", urlFor(to));
            xhr.send();
            ok(xhr, "rename", from);
        },
    };
    // Some plugins use the callback forms. They run the same requests
    // one turn later.
    for (const name of ["readFile", "writeFile", "unlink", "mkdir", "readdir", "stat", "rename", "rmdir"]) {
        fs[name] = (...args) => {
            const callback = typeof args[args.length - 1] === "function" ? args.pop() : () => {};
            setTimeout(() => {
                let result;
                try {
                    result = fs[name + "Sync"](...args);
                } catch (error) {
                    return callback(error);
                }
                callback(null, result);
            });
        };
    }
    fs.exists = (p, callback) => setTimeout(() => callback(fs.existsSync(p)));

    // MARK: NW.js

    const exit = () => post({ type: "exit" });
    const noop = () => {};
    // A plugin can call any window method (maximize, setResizable, ...).
    // None of them mean anything in a phone app.
    const nwWindow = new Proxy({}, { get: (target, key) => (key in target ? target[key] : noop) });
    const nwApp = { argv: [], manifest: {}, quit: exit, closeAllWindows: exit };
    const nwGui = { App: nwApp, Window: { get: () => nwWindow }, Menu: class { createMacBuiltin() {} } };
    const os = { platform: () => "linux", homedir: () => "/", tmpdir: () => "/", EOL: "\n" };
    const modules = { fs, path, os, "nw.gui": nwGui };

    window.nw = nwGui;
    window.require = (name) => {
        const found = modules[name.replace(/^node:/, "")];
        if (found) return found;
        const error = new Error(`Cannot find module '${name}'`);
        error.code = "MODULE_NOT_FOUND";
        throw error;
    };
    // MZ's main.js stops with an error when this path starts with
    // /private/var, so it must stay relative to the game folder.
    window.process = {
        platform: "linux",
        env: {},
        argv: [],
        versions: {},
        cwd: () => "/",
        exit,
        on: noop,
        mainModule: { filename: "/index.html" },
    };
    window.chrome = Object.assign(window.chrome || {}, { runtime: { reload: () => location.reload() } });
    window.close = exit;

    // Empo reads the controllers itself and sends them as keys. The
    // engine would read them a second time through this API.
    navigator.getGamepads = () => [];

    // MZ updates the game only while the page has focus. The app window
    // keeps the focus, and the app pauses the game when it goes away.
    Document.prototype.hasFocus = () => true;

    // MARK: frames, pause, and speed

    const nativeRequestFrame = window.requestAnimationFrame.bind(window);
    const waiting = new Map();
    let nextId = 1;
    let scheduled = false;
    let paused = false;
    let reportFrame = true;
    let frames = 0;
    let speed = settings.speed;
    let speedApplied = false;
    let size = "";

    const applySpeed = () => {
        if (typeof SceneManager === "undefined") return;
        if (SceneManager.determineRepeatNumber) {
            // MZ runs as many updates as this says for each frame.
            if (!speedApplied) {
                const repeat = SceneManager.determineRepeatNumber;
                SceneManager.determineRepeatNumber = function (deltaTime) {
                    return repeat.call(this, deltaTime) * speed;
                };
            }
        } else {
            // MV runs one update for each _deltaTime seconds of real time.
            SceneManager._deltaTime = 1 / 60 / speed;
        }
        speedApplied = true;
    };

    const runFrame = (time) => {
        scheduled = false;
        if (paused) return;
        const callbacks = [...waiting.values()];
        waiting.clear();
        if (!speedApplied) {
            // The simulator says that it plays Ogg, then fails to decode
            // it. MZ has its own decoder for a browser without Ogg.
            if (settings.simulator && typeof Utils !== "undefined") Utils.canPlayOgg = () => false;
            applySpeed();
        }
        for (const callback of callbacks) callback(time);
        frames++;
        if (reportFrame) {
            reportFrame = false;
            post({ type: "frame" });
        }
        // A game or a plugin can change the resolution from any script,
        // and no event reports it.
        if (typeof Graphics !== "undefined" && Graphics.width) {
            const next = Graphics.width + "x" + Graphics.height;
            if (next !== size) {
                size = next;
                post({ type: "size", width: Graphics.width, height: Graphics.height });
            }
        }
    };

    const schedule = () => {
        if (!scheduled && !paused && waiting.size) {
            scheduled = true;
            nativeRequestFrame(runFrame);
        }
    };

    window.requestAnimationFrame = (callback) => {
        const id = nextId++;
        waiting.set(id, callback);
        schedule();
        return id;
    };
    window.cancelAnimationFrame = (id) => waiting.delete(id);

    // MV keeps its PIXI renderer in Graphics._renderer, MZ in
    // Graphics._app. Neither exists until the game boots.
    const engineDetails = () => {
        if (typeof Utils === "undefined" || typeof Graphics === "undefined") return null;
        const renderer = Graphics._renderer || (Graphics._app && Graphics._app.renderer);
        if (!renderer) return null;
        const gl = renderer.gl;
        const mode = !gl ? "Canvas" : gl instanceof WebGL2RenderingContext ? "WebGL 2" : "WebGL 1";
        return [`RPG Maker ${Utils.RPGMAKER_NAME} ${Utils.RPGMAKER_VERSION}`, `PixiJS ${PIXI.VERSION} (${mode})`];
    };

    let detailsSent = false;
    let frameMark = performance.now();
    setInterval(() => {
        const now = performance.now();
        if (!detailsSent) {
            const lines = engineDetails();
            if (lines) {
                post({ type: "details", lines });
                detailsSent = true;
            }
        }
        post({ type: "fps", fps: (frames * 1000) / (now - frameMark) });
        frameMark = now;
        frames = 0;
    }, 1000);

    let playingMedia = [];
    const audioContext = () => (typeof WebAudio !== "undefined" ? WebAudio._context : null);

    const keyNames = {
        13: "Enter", 27: "Escape", 8: "Backspace", 9: "Tab", 32: " ", 16: "Shift", 17: "Control", 18: "Alt",
        33: "PageUp", 34: "PageDown", 35: "End", 36: "Home", 37: "ArrowLeft", 38: "ArrowUp", 39: "ArrowRight",
        40: "ArrowDown", 45: "Insert", 46: "Delete",
    };
    // SDL scancode to the DOM keyCode that Input.keyMapper reads.
    const keyCodes = { 40: 13, 41: 27, 42: 8, 43: 9, 44: 32, 73: 45, 74: 36, 75: 33, 76: 46, 77: 35, 78: 34,
        79: 39, 80: 37, 81: 40, 82: 38, 98: 96, 224: 17, 225: 16, 226: 18, 228: 17, 229: 16, 230: 18 };
    for (let i = 0; i < 26; i++) keyCodes[4 + i] = 65 + i;
    for (let i = 0; i < 9; i++) keyCodes[30 + i] = 49 + i;
    keyCodes[39] = 48;
    for (let i = 0; i < 12; i++) keyCodes[58 + i] = 112 + i;
    for (let i = 0; i < 9; i++) keyCodes[89 + i] = 97 + i;

    window.__mvmz = {
        key(scancode, pressed) {
            const keyCode = keyCodes[scancode];
            if (!keyCode) return;
            const key = keyNames[keyCode] || String.fromCharCode(keyCode).toLowerCase();
            const event = new KeyboardEvent(pressed ? "keydown" : "keyup", { key, bubbles: true, cancelable: true });
            Object.defineProperty(event, "keyCode", { get: () => keyCode });
            Object.defineProperty(event, "which", { get: () => keyCode });
            (document.activeElement || document).dispatchEvent(event);
        },
        pause() {
            paused = true;
            const context = audioContext();
            if (context && context.state === "running") context.suspend();
            playingMedia = [...document.querySelectorAll("video, audio")].filter((m) => !m.paused);
            playingMedia.forEach((m) => m.pause());
        },
        resume() {
            paused = false;
            const context = audioContext();
            if (context && context.state === "suspended") context.resume();
            playingMedia.forEach((m) => m.play());
            playingMedia = [];
            // MV counts the time since its last update, and would run
            // up to 15 updates at once to catch up with the pause.
            if (typeof SceneManager !== "undefined" && "_currentTime" in SceneManager) {
                SceneManager._currentTime = performance.now();
            }
            reportFrame = true;
            schedule();
        },
        setSpeed(multiplier) {
            speed = multiplier;
            applySpeed();
        },
    };

    // MARK: log

    for (const level of ["log", "info", "warn", "error"]) {
        const original = console[level].bind(console);
        console[level] = (...args) => {
            original(...args);
            post({ type: "log", text: `console.${level}: ${args.map(String).join(" ")}` });
        };
    }
    window.addEventListener("error", (e) =>
        post({ type: "log", text: `error: ${e.message} at ${e.filename}:${e.lineno}` }));
    window.addEventListener("unhandledrejection", (e) =>
        post({ type: "log", text: `unhandled rejection: ${e.reason}` }));

    if (!settings.smooth) {
        document.addEventListener("DOMContentLoaded", () => {
            const style = document.createElement("style");
            style.textContent = "canvas, video { image-rendering: pixelated; }";
            document.head.appendChild(style);
        });
    }
})();
