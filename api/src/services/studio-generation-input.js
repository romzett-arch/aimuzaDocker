const cleanText = (value, limit) => typeof value === 'string' ? value.trim().slice(0, limit) : '';
const validUuid = (value) => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

function inputError(message) {
  const error = new Error(message);
  error.status = 400;
  return error;
}

export function normalizeStudioGeneration(body) {
  const mode = body?.mode === 'custom' ? 'custom' : body?.mode === 'simple' ? 'simple' : null;
  const requestId = body?.requestId;
  if (!validUuid(requestId)) throw inputError('Укажите корректный идентификатор запроса');
  if (!mode) throw inputError('Выберите режим генерации');
  const prompt = cleanText(body?.prompt, 3000);
  const title = cleanText(body?.title, 100);
  const lyrics = cleanText(body?.lyrics, 5000);
  const style = cleanText(body?.style, 1000);
  const negativeTags = cleanText(body?.negativeTags, 1000);
  const instrumental = body?.instrumental === true;
  const vocalGender = body?.vocalGender === 'm' || body?.vocalGender === 'f' ? body.vocalGender : undefined;
  const duration = body?.duration == null || body.duration === '' ? undefined : Number(body.duration);
  const tempo = body?.tempo == null || body.tempo === '' || body.tempo === 0 ? undefined : Number(body.tempo);
  if (tempo !== undefined && (!Number.isInteger(tempo) || tempo < 1 || tempo > 240 || mode !== 'custom')) throw inputError('Темп должен быть целым числом от 1 до 240 BPM в режиме «Свой текст»');
  const songIdeaId = body?.songIdeaId || undefined;
  if (songIdeaId !== undefined && !validUuid(songIdeaId)) throw inputError('Некорректная идея для песни');
  if (duration !== undefined && (!Number.isInteger(duration) || duration < 10 || duration > 360 || mode !== 'custom')) throw inputError('Длительность доступна в режиме «Свой текст»: от 10 до 360 секунд');
  if (mode === 'simple' && !prompt) throw inputError('Опишите песню, которую нужно создать');
  if (mode === 'custom') {
    if (!style) throw inputError('Укажите стиль и аранжировку');
    if (!instrumental && !lyrics) throw inputError('Добавьте текст песни или выберите инструментал');
  }
  return { requestId, mode, prompt, title, lyrics, style, negativeTags, instrumental, vocalGender, duration, tempo, songIdeaId };
}

export function studioSunoPayload(input, tracks) {
  return {
    trackId: tracks[0].id, trackIds: tracks.map((track) => track.id),
    customMode: input.mode === 'custom', prompt: input.prompt || input.title,
    lyrics: input.lyrics || undefined,
    style: input.tempo ? input.style.slice(0, 980) + ', ' + input.tempo + ' BPM' : input.style,
    title: input.title || 'Новый трек', instrumental: input.instrumental,
    negativeTags: input.negativeTags || undefined, vocalGender: input.vocalGender,
    duration: input.duration,
  };
}
