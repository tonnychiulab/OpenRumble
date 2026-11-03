export function isEnter(data: string): boolean {
  return data === "\r" || data === "\n";
}

export function isEscape(data: string): boolean {
  return data === "\x1b" || data === "\x1b\x1b";
}

export function isUp(data: string): boolean {
  return data === "\x1b[A" || data === "\x1bOA" || data === "\x10";
}

export function isDown(data: string): boolean {
  return data === "\x1b[B" || data === "\x1bOB" || data === "\x0e";
}

export function isCtrlC(data: string): boolean {
  return data === "\x03";
}

export function isCtrlL(data: string): boolean {
  return data === "\x0c";
}

export function isBackspace(data: string): boolean {
  return data === "\x7f" || data === "\b";
}
