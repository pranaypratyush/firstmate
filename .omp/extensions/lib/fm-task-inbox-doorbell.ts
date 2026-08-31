import {
	type FSWatcher,
	existsSync,
	linkSync,
	mkdirSync,
	readFileSync,
	readdirSync,
	renameSync,
	unlinkSync,
	watch,
	writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";

export const FM_TASK_INBOX_DOORBELL_SIGNAL = "SIGUSR2";

type TaskInboxDoorbellMessage = {
	customType: string;
	content: string;
	display: boolean;
	attribution: "agent";
	details: { kind: "task-inbox"; runtime: "omp" };
};

type OmpDoorbellApi = {
	sendMessage?: (
		message: TaskInboxDoorbellMessage,
		options: { deliverAs: "steer"; triggerTurn: true },
	) => void;
};

export type TaskInboxDoorbellOptions = {
	inboxDir?: string;
	readyMarker?: string;
	deliverSession?: (expectedSession: string, message: TaskInboxDoorbellMessage) => boolean;
};

export type TaskInboxDoorbell = {
	activate: () => void;
	retire: () => void;
};

type ConfiguredDoorbellOptions = Pick<TaskInboxDoorbellOptions, "inboxDir" | "readyMarker"> & {
	inboxDir: string;
	readyMarker: string;
};

function configuredOptions(options: TaskInboxDoorbellOptions): ConfiguredDoorbellOptions | undefined {
	const inboxDir = options.inboxDir ?? process.env.FM_OMP_TASK_INBOX_DIR ?? "";
	const readyMarker = options.readyMarker ?? process.env.FM_OMP_TASK_DOORBELL_READY ?? "";
	if (!inboxDir.startsWith("/") || !readyMarker.startsWith("/")) return undefined;
	return { inboxDir, readyMarker };
}

function publishReadyMarker(marker: string): void {
	mkdirSync(dirname(marker), { recursive: true });
	const staged = `${marker}.staging.${process.pid}`;
	writeFileSync(staged, `${process.pid}\n`, { mode: 0o600 });
	renameSync(staged, marker);
}

function retireOwnedReadyMarker(marker: string): void {
	try {
		if (readFileSync(marker, "utf8") === `${process.pid}\n`) unlinkSync(marker);
	} catch {
		// Marker cleanup is best-effort; a stale marker cannot pass backend PID ownership checks.
	}
}

function bestEffortRename(from: string, to: string): void {
	try {
		renameSync(from, to);
	} catch {
		return;
	}
}

function bestEffortUnlink(path: string): void {
	try {
		unlinkSync(path);
	} catch {
		return;
	}
}

function requestContent(raw: string): { content: string; expectedSession?: string } | undefined {
	if (!raw.startsWith("omp_session=")) return { content: raw };
	const separator = raw.indexOf("\n--\n");
	if (separator < 0) return undefined;
	const expectedSession = raw.slice("omp_session=".length, separator);
	if (!expectedSession.startsWith("/") || !expectedSession.endsWith(".jsonl")) return undefined;
	return { content: raw.slice(separator + "\n--\n".length), expectedSession };
}

function reconcileAmbiguousClaims(requestDir: string): void {
	for (const name of readdirSync(requestDir).sort()) {
		const match = name.match(/^(.*\.pending)\.processing\.([0-9]+)$/);
		if (!match) continue;
		const processing = join(requestDir, name);
		const pending = join(requestDir, match[1]);
		const ambiguous = `${pending}.ambiguous`;
		try {
			linkSync(processing, ambiguous);
		} catch {
			if (!existsSync(ambiguous)) continue;
		}
		bestEffortUnlink(processing);
		bestEffortUnlink(pending);
	}
}

export function installTaskInboxDoorbell(
	omp: OmpDoorbellApi,
	options: TaskInboxDoorbellOptions = {},
): TaskInboxDoorbell {
	const configured = configuredOptions(options);
	if (!configured || typeof omp.sendMessage !== "function") {
		return { activate: () => {}, retire: () => {} };
	}

	const requestDir = `${configured.readyMarker}.requests`;
	let active = false;
	let draining = false;
	let signalHandlerInstalled = false;
	let watcher: FSWatcher | undefined;
	const retire = (): void => {
		if (!active) return;
		retireOwnedReadyMarker(configured.readyMarker);
		active = false;
		watcher?.close();
		watcher = undefined;
	};
	const drain = (): void => {
		if (!active || draining) return;
		draining = true;
		try {
			for (const name of readdirSync(requestDir).filter((entry) => entry.endsWith(".pending")).sort()) {
				const pending = join(requestDir, name);
				const ambiguous = `${pending}.ambiguous`;
				let invoked = false;
				try {
					renameSync(pending, ambiguous);
				} catch {
					continue;
				}
				try {
					if (typeof omp.sendMessage !== "function") throw new Error("OMP sendMessage unavailable");
					const request = requestContent(readFileSync(ambiguous, "utf8"));
					if (request === undefined) {
						renameSync(ambiguous, `${pending}.refused`);
						continue;
					}
					const message: TaskInboxDoorbellMessage = {
						customType: "firstmate-task-inbox-doorbell",
						content: request.content,
						display: false,
						attribution: "agent",
						details: { kind: "task-inbox", runtime: "omp" },
					};
					if (request.expectedSession) {
						invoked = true;
						if (!options.deliverSession?.(request.expectedSession, message)) {
							invoked = false;
							renameSync(ambiguous, `${pending}.refused`);
							continue;
						}
					} else {
						invoked = true;
						omp.sendMessage(message, { deliverAs: "steer", triggerTurn: true });
					}
					renameSync(ambiguous, `${pending}.delivered`);
				} catch {
					if (!invoked) bestEffortRename(ambiguous, `${pending}.failed`);
					retire();
					break;
				}
			}
		} finally {
			draining = false;
		}
	};
	const activate = (): void => {
		if (active) return;
		try {
			mkdirSync(requestDir, { recursive: true, mode: 0o700 });
			reconcileAmbiguousClaims(requestDir);
			watcher = watch(requestDir, drain);
			active = true;
			if (!signalHandlerInstalled) {
				process.on(FM_TASK_INBOX_DOORBELL_SIGNAL, drain);
				signalHandlerInstalled = true;
			}
			publishReadyMarker(configured.readyMarker);
			drain();
		} catch {
			retire();
		}
	};

	return { activate, retire };
}
