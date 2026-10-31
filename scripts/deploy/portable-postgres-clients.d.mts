export const CLIENT_IMAGE: string;
export const CLIENT_VERSION: string;
export function portableClientManifest(): {version:number;clientVersion:string;platform:string;sourceImage:string;files:Array<{file:string;bytes:number;sha256:string}>};
export type PortablePostgresClient = {directory:string;binDir:string;psql:string;pgDump:string;pgRestore:string;manifestSha256:string;version:string;sourceImage:string};
export function validatePortablePostgresClient(directory:string):Promise<PortablePostgresClient>;
export function buildPortablePostgresClient(directory:string,execute?:(args:string[])=>Promise<string>):Promise<PortablePostgresClient>;
