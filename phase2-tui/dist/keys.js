export function isEnter(data) {
    return data === "\r" || data === "\n";
}
export function isEscape(data) {
    return data === "\x1b" || data === "\x1b\x1b";
}
export function isUp(data) {
    return data === "\x1b[A" || data === "\x1bOA" || data === "\x10";
}
export function isDown(data) {
    return data === "\x1b[B" || data === "\x1bOB" || data === "\x0e";
}
export function isCtrlC(data) {
    return data === "\x03";
}
export function isCtrlL(data) {
    return data === "\x0c";
}
export function isBackspace(data) {
    return data === "\x7f" || data === "\b";
}
