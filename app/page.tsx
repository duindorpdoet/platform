import { HomeNews } from "@/components/editorial/home-news";
import { HomePage } from "@/components/brand/home-page";

export default function Page() {
  return <HomePage news={<HomeNews />} />;
}
