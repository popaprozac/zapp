import { Services } from "@zappdev/runtime";

export async function noop(args?: Record<string, unknown>): Promise<unknown> {
    return Services.invoke("noop", args ?? {});
}
