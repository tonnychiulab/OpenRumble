import { fit } from "./width.js";
export class Screen {
    app;
    previous = [];
    active = false;
    onData = null;
    constructor(app) {
        this.app = app;
    }
    start() {
        if (!process.stdin.isTTY || !process.stdout.isTTY) {
            throw new Error("此 TUI 需要互動式終端。可先執行 node dist/main.js --self-check。");
        }
        this.app.onChange = () => this.paint(this.app.consumeFullRedraw());
        this.app.onExit = (code) => {
            this.stop();
            process.exit(code);
        };
        process.stdout.write("\x1b[?1049h\x1b[?25l");
        process.stdin.setRawMode(true);
        process.stdin.resume();
        process.stdin.setEncoding("utf8");
        this.onData = (chunk) => {
            this.app.handleInput(chunk);
            this.paint(this.app.consumeFullRedraw());
        };
        process.stdin.on("data", this.onData);
        process.stdout.on("resize", this.onResize);
        this.active = true;
        this.app.start();
        this.paint(true);
    }
    stop() {
        if (!this.active)
            return;
        this.app.stop();
        if (this.onData)
            process.stdin.off("data", this.onData);
        process.stdout.off("resize", this.onResize);
        if (process.stdin.isTTY)
            process.stdin.setRawMode(false);
        process.stdout.write("\x1b[0m\x1b[?25h\x1b[?1049l");
        this.active = false;
    }
    onResize = () => {
        this.paint(true);
    };
    paint(full) {
        const width = process.stdout.columns || 80;
        const height = process.stdout.rows || 24;
        this.app.setViewport(height);
        const lines = this.app.render(width).slice(0, height).map((line) => fit(line, width));
        while (lines.length < height)
            lines.push("");
        const chunks = ["\x1b[?2026h"];
        const geometryChanged = lines.length !== this.previous.length;
        if (full || geometryChanged) {
            chunks.push("\x1b[H");
            for (let index = 0; index < lines.length; index += 1) {
                chunks.push(`\x1b[2K${lines[index] ?? ""}${index < lines.length - 1 ? "\r\n" : ""}`);
            }
        }
        else {
            for (let index = 0; index < lines.length; index += 1) {
                if (lines[index] !== this.previous[index]) {
                    chunks.push(`\x1b[${index + 1};1H\x1b[2K${lines[index] ?? ""}`);
                }
            }
        }
        chunks.push("\x1b[?2026l");
        process.stdout.write(chunks.join(""));
        this.previous = lines;
    }
}
