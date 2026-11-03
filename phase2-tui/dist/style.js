export const reset = "\x1b[0m";
export const dim = "\x1b[2m";
export const bold = "\x1b[1m";
export const red = "\x1b[1;31m";
export const green = "\x1b[1;32m";
export const yellow = "\x1b[1;33m";
export const cyan = "\x1b[1;36m";
export const bgBlue = "\x1b[44;37m";
export const bgRed = "\x1b[41;37m";
export function paint(text, open) {
    return `${open}${text}${reset}`;
}
