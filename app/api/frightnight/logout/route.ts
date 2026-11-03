import { cookies } from "next/headers";
import { apiFailure, apiSuccess, assertTrustedOrigin, correlationId } from "@/lib/http/api";
export async function POST(request: Request) {
  try {
    assertTrustedOrigin(request);
    const jar = await cookies();
    jar.delete("frightnight-edition"); jar.delete("frightnight-edition-cache");
    return apiSuccess({ cleared: true });
  } catch (error) { return apiFailure(error, correlationId(request)); }
}
