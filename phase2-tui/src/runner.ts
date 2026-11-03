import { spawn } from "node:child_process";

export interface RunRequest {
  file: string;
  args: readonly string[];
  cwd: string;
}

export interface RunningTask {
  abort: () => void;
  finished: Promise<number | null>;
}

export interface TaskRunner {
  start(request: RunRequest, onLine: (line: string) => void): RunningTask;
}

export const LOG_TAIL =
  "tail -n 80 /opt/zeek/logs/current/*.log 2>/dev/null || echo '目前沒有 Zeek current 日誌'";

export function startProcess(request: RunRequest, onLine: (line: string) => void): RunningTask {
  const child = spawn(request.file, [...request.args], {
    cwd: request.cwd,
    stdio: ["ignore", "pipe", "pipe"],
    detached: process.platform !== "win32",
    windowsHide: true,
  });
  let aborted = false;
  let buffer = "";
  const push = (chunk: Buffer): void => {
    buffer += chunk.toString("utf8").replace(/\r/g, "");
    const parts = buffer.split("\n");
    buffer = parts.pop() ?? "";
    for (const part of parts) onLine(part);
  };
  child.stdout?.on("data", push);
  child.stderr?.on("data", push);
  const finished = new Promise<number | null>((resolve) => {
    child.on("error", () => resolve(null));
    child.on("close", (code) => {
      if (buffer.length > 0) onLine(buffer);
      resolve(aborted ? null : code);
    });
  });
  return {
    abort: () => {
      aborted = true;
      if (child.pid === undefined) return;
      if (process.platform !== "win32") {
        try {
          process.kill(-child.pid, "SIGTERM");
          return;
        } catch {
          // The process group may already be gone.
        }
      }
      child.kill("SIGTERM");
    },
    finished,
  };
}
