import { handle } from "../build/dev/javascript/harmony/api.mjs";

export default {
  async fetch(request, env, ctx) {
    try {
      return await handle(request, env, ctx);
    } catch (error) {
      console.error("unhandled error", error);
      return new Response(JSON.stringify({ error: "サーバー内部エラー" }), {
        status: 500,
        headers: { "content-type": "application/json; charset=utf-8" },
      });
    }
  },
};
