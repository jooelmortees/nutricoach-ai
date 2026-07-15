const TRANSIENT_STATUSES = new Set([408, 429, 500, 502, 503, 504]);
const MAX_ATTEMPTS_PER_MODEL = 2;
const STREAMING_HEADER_TIMEOUT_MS = 15_000;
const NON_STREAMING_HEADER_TIMEOUT_MS = 90_000;

interface GeminiChatCompletionOptions {
  apiKey: string;
  baseUrl: string;
  primaryModel: string;
  fallbackModel: string;
  preferredModel?: string;
  headerTimeoutMs?: number;
  deadlineAt?: number;
  body: Record<string, unknown>;
}

interface GeminiChatCompletionResult {
  response: Response;
  model: string;
}

export async function fetchGeminiChatCompletion(
  options: GeminiChatCompletionOptions,
): Promise<GeminiChatCompletionResult> {
  const initialModel = options.preferredModel ?? options.primaryModel;
  const models = [initialModel];
  if (
    initialModel === options.primaryModel &&
    options.fallbackModel !== options.primaryModel
  ) {
    models.push(options.fallbackModel);
  }

  let lastError: unknown;

  for (let modelIndex = 0; modelIndex < models.length; modelIndex++) {
    const model = models[modelIndex];

    for (let attempt = 0; attempt < MAX_ATTEMPTS_PER_MODEL; attempt++) {
      try {
        const configuredTimeoutMs = options.headerTimeoutMs ?? (
          options.body.stream === true
            ? STREAMING_HEADER_TIMEOUT_MS
            : NON_STREAMING_HEADER_TIMEOUT_MS
        );
        const remainingMs = options.deadlineAt === undefined
          ? configuredTimeoutMs
          : options.deadlineAt - Date.now();
        if (remainingMs <= 0) {
          throw new Error("Se agoto el tiempo disponible para Gemini");
        }
        const headerTimeoutMs = Math.min(configuredTimeoutMs, remainingMs);
        const response = await fetchWithHeaderTimeout(
          `${options.baseUrl}/chat/completions`,
          {
            method: "POST",
            headers: {
              "Authorization": `Bearer ${options.apiKey}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ ...options.body, model }),
          },
          headerTimeoutMs,
        );

        if (response.ok || !TRANSIENT_STATUSES.has(response.status)) {
          return { response, model };
        }

        const hasFallback = modelIndex + 1 < models.length;
        const shouldFallbackImmediately = response.status === 503 && hasFallback;
        const hasRetry = !shouldFallbackImmediately &&
          attempt + 1 < MAX_ATTEMPTS_PER_MODEL;
        if (!hasRetry && !hasFallback) {
          return { response, model };
        }

        const delayMs = hasRetry ? getRetryDelayMs(response, attempt) : 0;
        console.warn(
          `Gemini ${model} devolvio ${response.status}. ` +
            (hasRetry
              ? `Reintento ${attempt + 2}/${MAX_ATTEMPTS_PER_MODEL} en ${delayMs} ms.`
              : `Usando fallback ${models[modelIndex + 1]}.`),
        );
        await response.body?.cancel();
        if (shouldFallbackImmediately) break;
        if (delayMs > 0) await sleep(delayMs);
      } catch (error) {
        lastError = error;
        const hasRetry = attempt + 1 < MAX_ATTEMPTS_PER_MODEL;
        const hasFallback = modelIndex + 1 < models.length;
        if (!hasRetry && !hasFallback) throw error;

        const delayMs = hasRetry ? getRetryDelayMs(null, attempt) : 0;
        console.warn(
          `Gemini ${model} fallo antes de responder: ${String(error)}. ` +
            (hasRetry
              ? `Reintento ${attempt + 2}/${MAX_ATTEMPTS_PER_MODEL} en ${delayMs} ms.`
              : `Usando fallback ${models[modelIndex + 1]}.`),
        );
        if (delayMs > 0) await sleep(delayMs);
      }
    }
  }

  throw lastError ?? new Error("Gemini no devolvio respuesta");
}

async function fetchWithHeaderTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

function getRetryDelayMs(response: Response | null, attempt: number): number {
  const retryAfterSeconds = Number(response?.headers.get("retry-after"));
  if (Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0) {
    return Math.min(retryAfterSeconds * 1_000, 10_000);
  }

  const exponentialDelay = 1_000 * (2 ** attempt);
  const jitter = Math.floor(Math.random() * 500);
  return Math.min(exponentialDelay + jitter, 5_000);
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
