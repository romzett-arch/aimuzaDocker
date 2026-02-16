import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const AGENT_ACCESS_ID = 'e046a9e4-43f6-47bc-a39f-8a9de8778d02';

// System prompt for generating style prompts from lyrics
const SYSTEM_PROMPT = `Ты эксперт по созданию музыки с помощью Suno AI. Твоя задача - анализировать текст песни и создавать промт для генерации музыки.

## ТВОЙ ПОДХОД

1. Внимательно прочитай текст песни
2. Если пользователь указал свои требования - ОБЯЗАТЕЛЬНО учитывай их в первую очередь
3. Определи настроение, жанр, темп, вокал на основе текста
4. Сгенерируй оптимальный промт для Suno на РУССКОМ языке

## ФОРМАТ ПРОМТА

Промт должен быть кратким и ёмким (до 200 символов), включать:
- Жанр и стиль музыки
- Настроение и атмосферу
- Тип вокала (если не инструментал)
- Темп и энергетику

## ПРИМЕРЫ ХОРОШИХ ПРОМПТОВ

- "Меланхоличный инди-поп, нежный женский вокал, медленный темп, атмосферная электроника"
- "Энергичный рок, мощный мужской вокал, драйвовые гитары, быстрый темп"
- "Лирический рэп, глубокий бас, минималистичный бит, городская атмосфера"
- "Романтическая баллада, акустическая гитара, тёплый вокал, интимная атмосфера"

## ФОРМАТ ОТВЕТА

Верни ТОЛЬКО валидный JSON (без markdown):
{
  "stylePrompt": "промт для Suno на русском языке (до 200 символов)",
  "genre": "определённый жанр",
  "mood": "настроение трека",
  "tempo": "медленный/средний/быстрый",
  "vocalStyle": "описание вокала"
}`;

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { lyrics, userPrompt } = await req.json();

    if (!lyrics || typeof lyrics !== 'string') {
      return new Response(
        JSON.stringify({ error: 'Текст песни обязателен' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const TIMEWEB_TOKEN = Deno.env.get('TIMEWEB_AGENT_TOKEN');
    if (!TIMEWEB_TOKEN) {
      console.error('TIMEWEB_AGENT_TOKEN is not configured');
      return new Response(
        JSON.stringify({ error: 'Timeweb Agent token не настроен' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('Генерация промта для текста, длина:', lyrics.length);

    // Build user prompt with optional requirements
    let userMessage = `Проанализируй этот текст песни и создай оптимальный промт для генерации музыки:\n\n${lyrics}`;
    
    if (userPrompt && userPrompt.trim()) {
      userMessage = `ТРЕБОВАНИЯ ПОЛЬЗОВАТЕЛЯ (учти их в первую очередь): ${userPrompt}\n\n${userMessage}`;
    }

    const apiUrl = `https://agent.timeweb.cloud/api/v1/cloud-ai/agents/${AGENT_ACCESS_ID}/v1/chat/completions`;

    const response = await fetch(apiUrl, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${TIMEWEB_TOKEN}`,
        'Content-Type': 'application/json',
        'x-proxy-source': 'lovable-app',
      },
      body: JSON.stringify({
        model: 'deepseek-v3.2',
        messages: [
          { role: 'system', content: SYSTEM_PROMPT },
          { role: 'user', content: userMessage }
        ],
        temperature: 0.7,
      }),
    });

    console.log('Timeweb response status:', response.status);

    if (!response.ok) {
      const errorText = await response.text();
      console.error('Timeweb API error:', response.status, errorText);
      
      if (response.status === 401) {
        return new Response(
          JSON.stringify({ error: 'Неверный токен Timeweb' }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      if (response.status === 429) {
        return new Response(
          JSON.stringify({ error: 'Превышен лимит запросов' }),
          { status: 429, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      return new Response(
        JSON.stringify({ error: 'Ошибка генерации промта', details: errorText }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const data = await response.json();
    console.log('Ответ получен, парсинг...');

    const content = data.choices?.[0]?.message?.content;
    if (!content) {
      console.error('Пустой ответ от AI');
      return new Response(
        JSON.stringify({ error: 'Пустой ответ от AI' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    let result;
    try {
      let jsonStr = content;
      const jsonMatch = content.match(/```(?:json)?\s*([\s\S]*?)```/);
      if (jsonMatch) {
        jsonStr = jsonMatch[1].trim();
      }
      result = JSON.parse(jsonStr);
    } catch (parseError) {
      console.error('JSON parse failed:', parseError);
      // Fallback: use content as stylePrompt
      result = {
        stylePrompt: content.slice(0, 200),
        genre: 'Неизвестно',
        mood: 'Неизвестно',
        tempo: 'средний',
        vocalStyle: 'Неизвестно'
      };
    }

    console.log('Промт создан:', result.stylePrompt?.slice(0, 50));

    return new Response(
      JSON.stringify(result),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Ошибка в analyze-lyrics:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Неизвестная ошибка' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});