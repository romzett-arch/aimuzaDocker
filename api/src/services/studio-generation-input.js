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
  const personaId = body?.personaId || undefined;
  const voiceProfileId = body?.voiceProfileId || undefined;
  const audioReference = body?.audioReference || undefined;
  const usePromo = body?.usePromo === true;
  if (usePromo && audioReference) throw inputError('Бонус на генерацию доступен без аудиореференса');
  if (voiceProfileId !== undefined && (mode !== 'custom' || !validUuid(voiceProfileId) || instrumental || personaId || audioReference)) {
    throw inputError('Выберите голос для песни с вокалом. Для этого режима уберите персону и аудиореференс.');
  }
  const weights = {};
  if (voiceProfileId) {
    for (const field of ['styleWeight', 'weirdnessConstraint', 'audioWeight']) {
      if (body[field] === undefined) continue;
      const value = body[field];
      if (!Number.isFinite(value) || value < 0 || value > 1 || Math.abs(Math.round(value * 100) - value * 100) > 1e-8) {
        throw inputError('Настройки влияния должны быть от 0 до 1 с точностью до двух знаков');
      }
      weights[field] = value;
    }
  }
  if (personaId !== undefined && (mode !== 'custom' || !validUuid(personaId))) throw inputError('Выберите персону в режиме «Свой текст»');
  if (audioReference !== undefined && (typeof audioReference !== 'string' || audioReference.length > 8192)) throw inputError('Прикрепите аудиореференс заново');
  if (songIdeaId !== undefined && !validUuid(songIdeaId)) throw inputError('Некорректная идея для песни');
  if (duration !== undefined && (!Number.isInteger(duration) || duration < 10 || duration > 360 || mode !== 'custom')) throw inputError('Длительность доступна в режиме «Свой текст»: от 10 до 360 секунд');
  if (mode === 'simple' && !prompt) throw inputError('Опишите песню, которую нужно создать');
  if (mode === 'simple' && audioReference && prompt.length > 500) throw inputError('С аудиореференсом описание должно содержать не более 500 символов');
  if (mode === 'custom') {
    if (!style) throw inputError('Укажите стиль и аранжировку');
    if (!instrumental && !lyrics) throw inputError('Добавьте текст песни или выберите инструментал');
  }
  return { requestId, mode, prompt, title, lyrics, style, negativeTags, instrumental, vocalGender, duration, tempo, songIdeaId, personaId, voiceProfileId, audioReference, ...(usePromo && {usePromo}), ...weights };
}

export function studioSunoPayload(input, tracks, { personaId, audioReferenceUrl } = {}) {
  return {
    trackId: tracks[0].id, trackIds: tracks.map((track) => track.id),
    customMode: input.mode === 'custom', prompt: input.prompt || input.title,
    lyrics: input.lyrics || undefined,
    style: input.tempo ? input.style.slice(0, 980) + ', ' + input.tempo + ' BPM' : input.style,
    title: input.title || 'Новый трек', instrumental: input.instrumental,
    negativeTags: input.negativeTags || undefined, vocalGender: input.voiceProfileId ? undefined : input.vocalGender,
    duration: input.duration,
    personaId,
    personaModel: personaId ? (input.voiceProfileId ? 'voice_persona' : 'style_persona') : undefined,
    styleWeight: input.styleWeight,
    weirdnessConstraint: input.weirdnessConstraint,
    audioWeight: input.audioWeight,
    audioReferenceUrl,
  };
}
