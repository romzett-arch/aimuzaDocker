const apiOrigin = "https://platform-api2.max.ru";

export function createMaxClient(token, origin = apiOrigin) {
  async function request(path, options = {}) {
    const response = await fetch(new URL(path, origin), {
      ...options,
      headers: { Authorization: token, ...options.headers },
      redirect: "error",
      signal: AbortSignal.timeout(8_000),
    });
    const data = await response.json().catch(() => null);
    if (!response.ok || !data || data.success === false) {
      const code = typeof data?.code === "string" && /^[a-z][a-z0-9_.-]{0,75}$/i.test(data.code)
        ? ` ${data.code}` : "";
      const error = new Error(`MAX API HTTP ${response.status}${code}`);
      error.status = response.status;
      throw error;
    }
    return data;
  }

  return {
    me: () => request("/me"),
    async upload(type, blob) {
      if (!blob || !blob.size || blob.size > 32 * 1024 * 1024) throw new Error("Invalid media size");
      const target = await request(`/uploads?type=${type}`, {method:"POST"});
      const url = new URL(target.url);
      const allowed = type==="image" ? ["iu.oneme.ru"] : ["omu.okcdn.ru","omub.okcdn.ru"];
      if (url.protocol!=="https:" || !allowed.includes(url.host)) throw new Error("Unexpected MAX upload host");
      const data = new FormData();
      const name = type==="audio" ? "aimuza.mp3" : `aimuza.${blob.type.split("/")[1] || "png"}`;
      data.set("data",blob,name);
      const response = await fetch(url, {
        method:"POST", body:data, redirect:"error", signal:AbortSignal.timeout(90_000),
        ...(type==="image" ? {headers:{Authorization:token}} : {}),
      });
      const result = await response.text();
      if (!response.ok) throw new Error(`MAX upload HTTP ${response.status}`);
      const fileToken = type==="image"
        ? Object.values(JSON.parse(result).photos ?? {})[0]?.token
        : /<retval>\s*1\s*<\/retval>/.test(result) ? target.token : null;
      if (!fileToken) throw new Error("MAX media upload incomplete");
      return {type,payload:{token:fileToken}};
    },
    send: ({ userId, chatId }, message) => request(
      Number.isSafeInteger(chatId) ? `/messages?chat_id=${chatId}` : `/messages?user_id=${userId}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(message),
    }),
  };
}
