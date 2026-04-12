import { Services } from "@zappdev/runtime";

export async function ping(args?: Record<string, unknown>): Promise<unknown> {
    return Services.invoke("ping", args ?? {});
}
