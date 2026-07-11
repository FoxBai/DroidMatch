#!/usr/bin/env node

import { spawn } from "node:child_process"
import { access, readFile } from "node:fs/promises"
import path from "node:path"
import process from "node:process"

const DEFAULT_ZCODE_CLI = "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs"
const MODEL_ALIASES = new Map([
    ["mimo", "mimo-v2.5-pro"],
    ["glm", "glm-5.2"],
    ["deepseek", "deepseek-v4-flash"],
])

const usage = `Usage:
  tools/zcode-model-prompt.mjs --list-models [--cwd <path>]
  tools/zcode-model-prompt.mjs --model <id|alias> --prompt <text> [options]
  printf '%s' '<prompt>' | tools/zcode-model-prompt.mjs --model mimo [options]

Options:
  --model <id|alias>          Exact catalog model ID, or mimo/glm/deepseek
  --provider <label>          Optional provider-label disambiguation
  --prompt <text>             Focused prompt text
  --prompt-file <path|->      Read prompt from a UTF-8 file, or stdin with -
  --max-output-tokens <n>     Positive output limit (default: 4096)
  --temperature <0...2>       Sampling temperature (default: 0)
  --timeout-seconds <n>       App-server request timeout (default: 180)
  --cwd <path>                Workspace directory (default: current directory)
  --zcode-cli <path>          Override the packaged zcode.cjs path
  --query-source <name>       Audit label (default: droidmatch-model-prompt)
  --require-suffix <text>     Fail unless trimmed output ends with this marker
  --json                      Emit model verification and text as JSON
  --list-models               List the configured workspace catalog; no model call
  -h, --help                  Show this help

The wrapper asks ZCode app-server for the live model catalog, selects the requested
model without reading credential files, calls workspace/generateText with a focused
context pack, and rejects a response whose model reference does not match.

中文：工具从 ZCode app-server 实时读取模型目录，不读取凭据文件；按模型创建
generateText 请求并复核响应模型，适合低 token 的定向审阅。`

function requireValue(argv, index, option) {
    const value = argv[index + 1]
    if (value === undefined || value.startsWith("--")) {
        throw new Error(`${option} requires a value`)
    }
    return value
}

function positiveInteger(value, option) {
    const parsed = Number(value)
    if (!Number.isInteger(parsed) || parsed <= 0) {
        throw new Error(`${option} must be a positive integer`)
    }
    return parsed
}

function boundedNumber(value, option, minimum, maximum) {
    const parsed = Number(value)
    if (!Number.isFinite(parsed) || parsed < minimum || parsed > maximum) {
        throw new Error(`${option} must be between ${minimum} and ${maximum}`)
    }
    return parsed
}

function parseArguments(argv) {
    const options = {
        cwd: process.cwd(),
        json: false,
        listModels: false,
        // Reasoning providers may exhaust a smaller ceiling before they emit
        // final text. This remains a limit, not a requested token spend.
        maxOutputTokens: 4096,
        provider: undefined,
        prompt: undefined,
        promptFile: undefined,
        querySource: "droidmatch-model-prompt",
        requireSuffix: undefined,
        temperature: 0,
        timeoutSeconds: 180,
        zcodeCli: process.env.ZCODE_CLI_PATH || DEFAULT_ZCODE_CLI,
    }

    for (let index = 0; index < argv.length; index += 1) {
        const argument = argv[index]
        switch (argument) {
        case "-h":
        case "--help":
            options.help = true
            break
        case "--json":
            options.json = true
            break
        case "--list-models":
            options.listModels = true
            break
        case "--model":
            options.model = requireValue(argv, index, argument)
            index += 1
            break
        case "--provider":
            options.provider = requireValue(argv, index, argument)
            index += 1
            break
        case "--prompt":
            options.prompt = requireValue(argv, index, argument)
            index += 1
            break
        case "--prompt-file":
            options.promptFile = requireValue(argv, index, argument)
            index += 1
            break
        case "--max-output-tokens":
            options.maxOutputTokens = positiveInteger(
                requireValue(argv, index, argument),
                argument
            )
            index += 1
            break
        case "--temperature":
            options.temperature = boundedNumber(
                requireValue(argv, index, argument),
                argument,
                0,
                2
            )
            index += 1
            break
        case "--timeout-seconds":
            options.timeoutSeconds = positiveInteger(
                requireValue(argv, index, argument),
                argument
            )
            index += 1
            break
        case "--cwd":
            options.cwd = requireValue(argv, index, argument)
            index += 1
            break
        case "--zcode-cli":
            options.zcodeCli = requireValue(argv, index, argument)
            index += 1
            break
        case "--query-source":
            options.querySource = requireValue(argv, index, argument)
            index += 1
            break
        case "--require-suffix":
            options.requireSuffix = requireValue(argv, index, argument)
            index += 1
            break
        default:
            throw new Error(`unknown argument: ${argument}`)
        }
    }

    if (options.prompt !== undefined && options.promptFile !== undefined) {
        throw new Error("--prompt and --prompt-file are mutually exclusive")
    }
    if (options.requireSuffix !== undefined && options.requireSuffix.trim().length === 0) {
        throw new Error("--require-suffix must not be empty")
    }
    return options
}

async function readStdin() {
    const chunks = []
    for await (const chunk of process.stdin) {
        chunks.push(Buffer.from(chunk))
    }
    return Buffer.concat(chunks).toString("utf8")
}

async function resolvePrompt(options) {
    if (options.prompt !== undefined) {
        return options.prompt
    }
    if (options.promptFile === "-") {
        return readStdin()
    }
    if (options.promptFile !== undefined) {
        return readFile(path.resolve(options.promptFile), "utf8")
    }
    if (!process.stdin.isTTY) {
        return readStdin()
    }
    throw new Error("provide --prompt, --prompt-file, or prompt text on stdin")
}

class ZCodeProtocolClient {
    constructor({ cliPath, cwd, timeoutSeconds }) {
        this.nextID = 1
        this.pending = new Map()
        this.stderr = ""
        this.timeoutMilliseconds = timeoutSeconds * 1000
        this.child = spawn(
            process.execPath,
            [cliPath, "app-server", "--cwd", cwd, "--no-color"],
            { cwd, stdio: ["pipe", "pipe", "pipe"] }
        )
        this.stdoutBuffer = ""
        this.child.stdout.setEncoding("utf8")
        this.child.stderr.setEncoding("utf8")
        this.child.stdout.on("data", chunk => this.receive(chunk))
        this.child.stderr.on("data", chunk => {
            this.stderr = `${this.stderr}${chunk}`.slice(-8000)
        })
        this.child.stdin.on("error", error => this.failPending(error))
        this.child.on("error", error => this.failPending(error))
        this.child.on("exit", (code, signal) => {
            if (this.pending.size === 0) {
                return
            }
            const detail = this.stderr.trim()
            const suffix = detail ? `: ${detail}` : ""
            this.failPending(
                new Error(`ZCode app-server exited code=${code} signal=${signal}${suffix}`)
            )
        })
    }

    receive(chunk) {
        this.stdoutBuffer += chunk
        while (true) {
            const newline = this.stdoutBuffer.indexOf("\n")
            if (newline < 0) {
                return
            }
            const line = this.stdoutBuffer.slice(0, newline).trim()
            this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1)
            if (line.length === 0) {
                continue
            }
            let message
            try {
                message = JSON.parse(line)
            } catch {
                // App-server stdout is the protocol channel. Skipping a damaged
                // record could associate a later response with the wrong request.
                this.failPending(new Error(`ZCode app-server emitted non-JSON output: ${line}`))
                continue
            }
            if (message.id === undefined) {
                continue
            }
            const pending = this.pending.get(String(message.id))
            if (pending === undefined) {
                continue
            }
            this.pending.delete(String(message.id))
            clearTimeout(pending.timeout)
            if (message.error !== undefined) {
                pending.reject(new Error(
                    `ZCode ${pending.method} failed (${message.error.code}): ${message.error.message}`
                ))
            } else {
                pending.resolve(message.result)
            }
        }
    }

    request(method, params) {
        const id = String(this.nextID)
        this.nextID += 1
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                this.pending.delete(id)
                reject(new Error(`ZCode ${method} timed out after ${this.timeoutMilliseconds} ms`))
            }, this.timeoutMilliseconds)
            this.pending.set(id, { method, reject, resolve, timeout })
            const payload = `${JSON.stringify({ id, method, params })}\n`
            try {
                this.child.stdin.write(payload, error => {
                    if (error === null || error === undefined) {
                        return
                    }
                    const active = this.pending.get(id)
                    if (active === undefined) {
                        return
                    }
                    this.pending.delete(id)
                    clearTimeout(active.timeout)
                    active.reject(error)
                })
            } catch (error) {
                const active = this.pending.get(id)
                if (active !== undefined) {
                    this.pending.delete(id)
                    clearTimeout(active.timeout)
                }
                reject(error)
            }
        })
    }

    failPending(error) {
        for (const pending of this.pending.values()) {
            clearTimeout(pending.timeout)
            pending.reject(error)
        }
        this.pending.clear()
    }

    stop() {
        this.child.stdin.end()
        this.child.kill("SIGTERM")
    }
}

function selectModel(available, requestedModel, requestedProvider) {
    const normalizedRequest = requestedModel.toLowerCase()
    const modelID = MODEL_ALIASES.get(normalizedRequest) || requestedModel
    const matches = available.filter(model => {
        const sameModel = model.ref.modelId.toLowerCase() === modelID.toLowerCase()
            || model.label.toLowerCase() === modelID.toLowerCase()
        const sameProvider = requestedProvider === undefined
            || model.providerLabel.toLowerCase() === requestedProvider.toLowerCase()
        return sameModel && sameProvider
    })
    if (matches.length === 0) {
        throw new Error(`model is not configured in this workspace: ${requestedModel}`)
    }
    if (matches.length > 1) {
        throw new Error(`model is ambiguous; add --provider: ${requestedModel}`)
    }
    return matches[0]
}

function printModels(models, asJSON) {
    if (asJSON) {
        console.log(JSON.stringify(models.map(model => ({
            contextWindow: model.contextWindow,
            label: model.label,
            maxOutputTokens: model.maxOutputTokens,
            modelId: model.ref.modelId,
            provider: model.providerLabel,
        })), null, 2))
        return
    }
    for (const model of models) {
        const outputLimit = model.maxOutputTokens ?? "unknown"
        console.log(
            `${model.providerLabel}\t${model.ref.modelId}`
                + `\tcontext=${model.contextWindow}\toutput=${outputLimit}`
        )
    }
}

async function main() {
    const options = parseArguments(process.argv.slice(2))
    if (options.help) {
        console.log(usage)
        return
    }

    options.cwd = path.resolve(options.cwd)
    options.zcodeCli = path.resolve(options.zcodeCli)
    await access(options.cwd)
    await access(options.zcodeCli)

    const workspace = {
        workspacePath: options.cwd,
        workspaceKey: options.cwd,
    }
    const client = new ZCodeProtocolClient({
        cliPath: options.zcodeCli,
        cwd: options.cwd,
        timeoutSeconds: options.timeoutSeconds,
    })

    try {
        const state = await client.request("workspace/readState", { workspace })
        const available = state.modelCatalog?.available || state.settings?.model?.available
        if (!Array.isArray(available) || available.length === 0) {
            throw new Error("ZCode workspace has no configured model catalog")
        }
        if (options.listModels) {
            printModels(available, options.json)
            return
        }
        if (options.model === undefined) {
            throw new Error("--model is required unless --list-models is used")
        }

        const selected = selectModel(available, options.model, options.provider)
        const prompt = (await resolvePrompt(options)).trim()
        if (prompt.length === 0) {
            throw new Error("prompt must not be empty")
        }
        const result = await client.request("workspace/generateText", {
            workspace,
            modelRef: selected.ref,
            prompt,
            querySource: options.querySource,
            maxOutputTokens: options.maxOutputTokens,
            temperature: options.temperature,
        })
        if (result.modelRef.modelId !== selected.ref.modelId
            || result.modelRef.providerId !== selected.ref.providerId
            || (result.modelRef.variant ?? null) !== (selected.ref.variant ?? null)) {
            throw new Error(
                `model verification failed: requested ${selected.ref.modelId}, `
                    + `received ${result.modelRef.modelId}`
            )
        }
        if (result.text.trim().length === 0) {
            throw new Error(
                "model returned empty text; it may have exhausted the output budget "
                    + "or produced no final answer; retry with --max-output-tokens 4096 or higher"
            )
        }
        if (options.requireSuffix !== undefined
            && !result.text.trim().endsWith(options.requireSuffix)) {
            throw new Error(
                `model output is incomplete: missing required suffix ${options.requireSuffix}`
                    + "; retry with --max-output-tokens 4096 or higher"
            )
        }

        if (options.json) {
            console.log(JSON.stringify({
                modelId: result.modelRef.modelId,
                provider: selected.providerLabel,
                providerId: result.modelRef.providerId,
                variant: result.modelRef.variant,
                text: result.text,
            }, null, 2))
        } else {
            console.error(
                `[zcode] verified model=${result.modelRef.modelId} `
                    + `provider=${selected.providerLabel}`
            )
            console.log(result.text)
        }
    } finally {
        client.stop()
    }
}

main().catch(error => {
    console.error(`zcode-model-prompt failed: ${error.message}`)
    process.exitCode = 1
})
