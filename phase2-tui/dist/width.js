const ANSI = /\x1b\[[0-9;]*m/g;
export function stripAnsi(text) {
    return text.replace(ANSI, "");
}
function charWidth(codePoint) {
    if (codePoint === 0 || codePoint < 32 || (codePoint >= 0x7f && codePoint < 0xa0))
        return 0;
    if ((codePoint >= 0x1100 && codePoint <= 0x115f) ||
        (codePoint >= 0x2329 && codePoint <= 0x232a) ||
        (codePoint >= 0x2e80 && codePoint <= 0xa4cf && codePoint !== 0x303f) ||
        (codePoint >= 0xac00 && codePoint <= 0xd7a3) ||
        (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
        (codePoint >= 0xfe10 && codePoint <= 0xfe19) ||
        (codePoint >= 0xfe30 && codePoint <= 0xfe6f) ||
        (codePoint >= 0xff00 && codePoint <= 0xff60) ||
        (codePoint >= 0xffe0 && codePoint <= 0xffe6) ||
        (codePoint >= 0x1f300 && codePoint <= 0x1f64f) ||
        (codePoint >= 0x1f900 && codePoint <= 0x1f9ff) ||
        (codePoint >= 0x20000 && codePoint <= 0x3fffd)) {
        return 2;
    }
    return 1;
}
export function visibleWidth(text) {
    const plain = stripAnsi(text);
    let width = 0;
    for (let index = 0; index < plain.length;) {
        const codePoint = plain.codePointAt(index) ?? 0;
        width += charWidth(codePoint);
        index += codePoint > 0xffff ? 2 : 1;
    }
    return width;
}
export function fit(text, width) {
    if (width <= 0)
        return "";
    let visible = 0;
    let out = "";
    let styled = false;
    for (let index = 0; index < text.length;) {
        if (text[index] === "\x1b" && text[index + 1] === "[") {
            const end = text.indexOf("m", index);
            if (end === -1)
                break;
            const sequence = text.slice(index, end + 1);
            out += sequence;
            styled = sequence !== "\x1b[0m";
            index = end + 1;
            continue;
        }
        const codePoint = text.codePointAt(index) ?? 0;
        const next = charWidth(codePoint);
        if (visible + next > width)
            break;
        out += String.fromCodePoint(codePoint);
        visible += next;
        index += codePoint > 0xffff ? 2 : 1;
    }
    if (styled)
        out += "\x1b[0m";
    return out;
}
export function padVisible(text, width) {
    const current = visibleWidth(text);
    if (current >= width)
        return fit(text, width);
    return text + " ".repeat(width - current);
}
