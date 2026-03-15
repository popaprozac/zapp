export declare const sleep: (ms: any) => Promise<unknown>;
export declare const preferredJsTool: () => any;
export declare const runCmd: (command: any, args: any, options?: {}) => Promise<unknown>;
export declare const spawnStreaming: (command: string, args: string[], options?: any) => import("child_process").ChildProcess;
export declare const killChild: (child: any) => void;
export declare const runPackageScript: (script: string, options?: any) => Promise<unknown>;
export declare const spawnPackageScript: (script: string, options?: any) => import("child_process").ChildProcess;
