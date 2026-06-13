#!/usr/bin/env bash
# Patch @a2anet/a2a-utils A2ASession: transient tasks/get HTTP errors should not
# discard a successful message/send (task id already created on the peer).
set -euo pipefail

ext_dir="${1:?usage: patch-a2a-outbound-resilience.sh <plugin-ext-dir>}"
session="${ext_dir}/node_modules/@a2anet/a2a-utils/dist/client/a2a-session.js"
tools="${ext_dir}/node_modules/@a2anet/a2a-utils/dist/client/a2a-tools.js"
[[ -f "$session" ]] || exit 0

python3 - "$session" "$tools" <<'PY'
import sys
from pathlib import Path

session = Path(sys.argv[1])
tools = Path(sys.argv[2]) if len(sys.argv) > 2 else None
text = session.read_text(encoding="utf-8")

if "identyclaw-a2a-outbound-resilience" in text:
    sys.exit(0)

old_poll = """        if (remaining > 0) {
            const supportsStreaming = agentCard.capabilities !== undefined &&
                agentCard.capabilities !== null &&
                agentCard.capabilities.streaming === true;
            if (supportsStreaming) {
                task = await this.getTaskStreaming(agentCard, headers, task.id, remaining);
            }
            else {
                task = await this.getTaskPolling(agentCard, headers, task.id, remaining, this.getTaskPollInterval);
            }
            await this.taskStore.save(task);
        }"""

new_poll = """        if (remaining > 0) {
            const supportsStreaming = agentCard.capabilities !== undefined &&
                agentCard.capabilities !== null &&
                agentCard.capabilities.streaming === true;
            try {
                if (supportsStreaming) {
                    task = await this.getTaskStreaming(agentCard, headers, task.id, remaining);
                }
                else {
                    task = await this.getTaskPolling(agentCard, headers, task.id, remaining, this.getTaskPollInterval);
                }
                await this.taskStore.save(task);
            }
            catch (pollErr) {
                console.warn(`[a2a] identyclaw-a2a-outbound-resilience: task ${task.id} monitor failed (${pollErr}); retrying fetch`);
                try {
                    await new Promise((resolve) => setTimeout(resolve, 1500));
                    const client = this.createClient(agentCard, headers);
                    task = await this.fetchTask(client, task.id, Math.max(5, Math.min(remaining, 30)));
                    await this.taskStore.save(task);
                }
                catch {
                    console.warn(`[a2a] identyclaw-a2a-outbound-resilience: returning in-flight task ${task.id}`);
                }
            }
        }"""

if old_poll not in text:
    sys.stderr.write(f"patch-a2a-outbound-resilience: sendMessage poll block not found in {session}\n")
    sys.exit(1)
text = text.replace(old_poll, new_poll, 1)

old_fetch = """    async fetchTask(client, taskId, timeout) {
        const response = await this.getSessionClient(client).getTask({ id: taskId }, timeout !== undefined
            ? { signal: AbortSignal.timeout(Math.round(timeout * 1000)) }
            : undefined);
        if ("error" in response) {
            throw new Error(`JSON-RPC error: ${response.error.message} (code: ${response.error.code})`);
        }
        const task = response.result;
        assertTaskIdentifiers(task);
        return task;
    }"""

new_fetch = """    async fetchTask(client, taskId, timeout) {
        const opts = timeout !== undefined
            ? { signal: AbortSignal.timeout(Math.round(timeout * 1000)) }
            : undefined;
        let lastErr;
        for (let attempt = 0; attempt < 4; attempt++) {
            try {
                const response = await this.getSessionClient(client).getTask({ id: taskId }, opts);
                if ("error" in response) {
                    throw new Error(`JSON-RPC error: ${response.error.message} (code: ${response.error.code})`);
                }
                const task = response.result;
                assertTaskIdentifiers(task);
                return task;
            }
            catch (err) {
                lastErr = err;
                const msg = String(err);
                const retryable = /\\b(400|401|403|408|429|500|502|503|504)\\b/.test(msg) ||
                    msg.toLowerCase().includes("tasks/get");
                if (!retryable || attempt >= 3) {
                    throw err;
                }
                await new Promise((resolve) => setTimeout(resolve, 400 * (attempt + 1)));
            }
        }
        throw lastErr;
    }"""

if old_fetch not in text:
    sys.stderr.write(f"patch-a2a-outbound-resilience: fetchTask block not found in {session}\n")
    sys.exit(1)
text = text.replace(old_fetch, new_fetch, 1)

old_stream_end = """        // Final fetch to get the complete Task with all artifacts
        return this.fetchTask(client, taskId, timeout);
    }"""

new_stream_end = """        // Final fetch to get the complete Task with all artifacts
        try {
            return await this.fetchTask(client, taskId, timeout);
        }
        catch (fetchErr) {
            const cached = this.taskStore ? await this.taskStore.load(taskId) : null;
            if (cached) {
                console.warn(`[a2a] identyclaw-a2a-outbound-resilience: fetchTask failed for ${taskId}, using cached task`);
                return cached;
            }
            throw fetchErr;
        }
    }"""

if old_stream_end not in text:
    sys.stderr.write(f"patch-a2a-outbound-resilience: getTaskStreaming tail not found in {session}\n")
    sys.exit(1)
text = text.replace(old_stream_end, new_stream_end, 1)

session.write_text(text, encoding="utf-8")

if tools and tools.is_file():
    ttext = tools.read_text(encoding="utf-8")
    if "identyclaw-a2a-send-recover" not in ttext:
        old_catch = """                return { error: true, error_message: `Failed to send message: ${e}` };
            }
        },
    };
    getTask = {"""

        new_catch = """                if (errorMsg.includes("tasks/get") || errorMsg.includes("400")) {
                    const cached = await this.session.taskStore?.load?.("");
                    void cached;
                    const recent = await this.recoverRecentOutboundTask(agentId);
                    if (recent) {
                        return await this.buildTaskForLlm(recent);
                    }
                }
                return { error: true, error_message: `Failed to send message: ${e}` };
            }
        },
    };
    getTask = {"""

        if old_catch not in ttext:
            sys.stderr.write(f"patch-a2a-outbound-resilience: sendMessage catch not found in {tools}\n")
        else:
            helper = """
    /** identyclaw-a2a-send-recover: last saved outbound task for agent after poll failure */
    async recoverRecentOutboundTask(agentId) {
        const store = this.session.taskStore;
        if (!store || typeof store.list !== "function") {
            return null;
        }
        try {
            const ids = await store.list();
            for (let i = ids.length - 1; i >= 0; i--) {
                const task = await store.load(ids[i]);
                if (task?.id) {
                    return task;
                }
            }
        }
        catch {
            return null;
        }
        return null;
    }
"""
            marker = "    async buildTaskForLlm(task) {"
            if marker in ttext and "recoverRecentOutboundTask" not in ttext:
                ttext = ttext.replace(marker, helper + marker, 1)
                ttext = ttext.replace(old_catch, new_catch, 1)
                tools.write_text(ttext, encoding="utf-8")
PY
