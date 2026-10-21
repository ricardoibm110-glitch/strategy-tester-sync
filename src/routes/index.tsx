import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Scalp WIN Pro — acompanhamento do robô" },
      { name: "description", content: "Acompanhamento do robô Scalp WIN Pro no MetaTrader 5." },
      { property: "og:title", content: "Scalp WIN Pro — acompanhamento do robô" },
      { property: "og:description", content: "Acompanhamento do robô Scalp WIN Pro no MetaTrader 5." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: Index,
});

// IMPORTANT: Replace this placeholder. See ./README.md for routing conventions.
function Index() {
  return (
    <div
      className="flex min-h-screen items-center justify-center"
      style={{ backgroundColor: "#fcfbf8" }}
    >
      <img
        data-lovable-blank-page-placeholder="REMOVE_THIS"
        src="https://cdn.gpteng.co/blank-app-v1.svg"
        alt="Your app will live here!"
      />
    </div>
  );
}
