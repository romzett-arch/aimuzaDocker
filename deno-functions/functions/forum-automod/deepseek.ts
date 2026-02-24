const TIMEWEB_AGENT_ACCESS_ID = '0846d064-4950-4d79-a54c-62ba315cdb34';

export async function callDeepSeek(systemPrompt: string, userMessage: string): Promise<string | null> {
  const TIMEWEB_TOKEN = Deno.env.get("TIMEWEB_AGENT_TOKEN");
  if (!TIMEWEB_TOKEN) {
    console.warn("[forum-automod] TIMEWEB_AGENT_TOKEN not configured");
    return null;
  }

  const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${TIMEWEB_AGENT_ACCESS_ID}/v1/chat/completions`;

  const response = await fetch(apiUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${TIMEWEB_TOKEN}`,
    },
    body: JSON.stringify({
      model: "deepseek-v3",
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userMessage },
      ],
      temperature: 0.1,
      max_tokens: 500,
    }),
  });

  if (!response.ok) {
    console.warn(`[forum-automod] DeepSeek API error: ${response.status}`);
    return null;
  }

  const data = await response.json();
  return data.choices?.[0]?.message?.content || null;
}
