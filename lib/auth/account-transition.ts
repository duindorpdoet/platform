import { safeReturnPath } from "./redirect";
let logoutDestination: string | null = null;
export function prepareAccountLogout(destination: string) { logoutDestination = safeReturnPath(destination, "/inloggen"); }
export function accountLogoutDestination() { return logoutDestination; }
