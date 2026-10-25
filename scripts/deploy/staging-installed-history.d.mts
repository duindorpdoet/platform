export const HOTFIX_BRANCH: string;
export const GROUP_OPERATIONS_BRANCH: string;
export const ISOLATED_RELEASE_BRANCHES: readonly string[];
export const STAGING_SOURCE_REVISION: string;
export const STAGING_INSTALLED_MIGRATIONS: Readonly<Record<string,string>>;
type Context = {APP_ENVIRONMENT?: string; GITHUB_REF?: string};
export function installedStagingHistory(context?: Context): string[];
export function missingInstalledFiles(repositoryFiles: string[], appliedVersions: string[], context?: Context): string[];
