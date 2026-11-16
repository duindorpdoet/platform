export function stagingAuthPolicy(env: Record<string,string|undefined>, request?: typeof fetch): Promise<{
  stagingAuthPolicy: string; functionVersion: number; matchedPolicyDigests: number; allowlistedRecipients: number;
  existingTestersPreserved: boolean; authenticationRequests: number; mailDelivery: number; secretMutations: number; readOnly: boolean;
}>;
