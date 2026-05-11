import { Services } from "@zappdev/runtime";

export async function echo(args?: Record<string, unknown>): Promise<unknown> {
    return Services.invoke("echo", args ?? {});
}
