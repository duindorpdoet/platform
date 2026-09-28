import "server-only";
import { createPrivilegedClient } from "@/lib/supabase/privileged";

type Candidate = { generationId: string; kind: "asset" | "all"; paths: string[] };

export async function cleanupSocialShareAssets() {
  const client = createPrivilegedClient();
  if (!client) return { removed: 0 };
  const result = await client.schema("api").rpc("worker_social_share_cleanup_candidates", { _limit: 50 });
  if (result.error) throw result.error;
  let removed = 0;
  for (const candidate of (result.data ?? []) as Candidate[]) {
    const storage = await client.storage.from("social-share-assets").remove(candidate.paths);
    if (storage.error) continue;
    const finalized = await client.schema("api").rpc("worker_social_share_cleanup_finalize", {
      _generation_id: candidate.generationId, _kind: candidate.kind,
    });
    if (!finalized.error) removed += candidate.paths.length;
  }
  return { removed };
}
