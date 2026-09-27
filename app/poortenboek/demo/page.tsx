import { notFound } from "next/navigation";
import { BookLogin } from "@/components/poortenboek/login";
import { canDemo } from "@/lib/poortenboek/server";
export default function DemoPage() {
  if (!canDemo()) notFound();
  return <BookLogin demo />;
}
