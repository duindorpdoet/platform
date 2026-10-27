export const WELCOME_VERSION = 1;
export type AccountTarget = { kind: "adult" | "child"; id: string };
export type AccountEnvironment = { id: string; kind: "parent" | "house" | "viewer" | "admin"; label: string; description: string; path: string };
export type AccountSnapshot = {
  userId: string;
  email: string;
  eventId: string;
  environments: AccountEnvironment[];
  children: Array<{ id: string; firstName: string }>;
  resume: AccountTarget | null;
  welcomeVersion: number;
};
