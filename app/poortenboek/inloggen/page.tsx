import { redirect } from "next/navigation";
import { BookLogin } from "@/components/poortenboek/login";
import { childSnapshot } from "@/lib/poortenboek/server";
export default async function LoginPage() {
  const snapshot = await childSnapshot();
  if (snapshot) redirect("/poortenboek");
  return <BookLogin />;
}
