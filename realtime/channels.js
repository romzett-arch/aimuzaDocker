export function matchFilter(filter, record) {
  const match = filter.match(/^(\w+)=eq\.(.+)$/);
  if (!match) return true;
  const [, col, val] = match;
  return String(record[col]) === val;
}

export function encodeMessage(msg) {
  return JSON.stringify([
    msg.join_ref ?? null,
    msg.ref ?? null,
    msg.topic ?? '',
    msg.event ?? '',
    msg.payload ?? {},
  ]);
}

export function send(ws, msg) {
  if (ws.readyState === 1) {
    ws.send(encodeMessage(msg));
  }
}

export function buildColumns(record, oldRecord) {
  const names = new Set([
    ...Object.keys(record || {}),
    ...Object.keys(oldRecord || {}),
  ]);

  return Array.from(names).map((name) => ({ name, type: 'text' }));
}

export function getPresenceState(presenceState, topic) {
  const state = presenceState.get(topic);
  if (!state) return {};
  const result = {};
  state.forEach((data, key) => {
    result[key] = { metas: data.metas };
  });
  return result;
}

export function removePresence(wss, clientSubs, presenceState, topic, key, ws) {
  const topicState = presenceState.get(topic);
  if (!topicState) return;

  const current = topicState.get(key);
  if (!current) return;

  const ref = ws?.__presenceRefs?.get(topic);
  const leavingMetas = ref
    ? current.metas.filter((meta) => meta.phx_ref === ref)
    : current.metas;
  if (leavingMetas.length === 0) return;

  const remainingMetas = ref
    ? current.metas.filter((meta) => meta.phx_ref !== ref)
    : [];
  if (remainingMetas.length > 0) {
    topicState.set(key, { metas: remainingMetas });
  } else {
    topicState.delete(key);
  }
  ws?.__presenceRefs?.delete(topic);
  if (topicState.size === 0) presenceState.delete(topic);

  const diff = {
    joins: {},
    leaves: { [key]: { metas: leavingMetas } },
  };
  broadcastPresenceDiff(wss, clientSubs, topic, diff);
}

export function broadcastPresenceDiff(wss, clientSubs, topic, diff) {
  wss.clients.forEach((ws) => {
    if (ws.readyState !== 1) return;
    const subs = clientSubs.get(ws);
    if (!subs || !subs.has(topic)) return;

    send(ws, { topic, event: 'presence_diff', payload: diff, ref: null });
  });
}

export function broadcastChange(wss, clientSubs, data) {
  const { table, schema, type, record, old_record } = data;
  const eventType = type === 'INSERT' ? 'INSERT' : type === 'UPDATE' ? 'UPDATE' : 'DELETE';
  const columns = buildColumns(record, old_record);

  wss.clients.forEach((ws) => {
    if (ws.readyState !== 1) return;
    const subs = clientSubs.get(ws);
    if (!subs) return;

    subs.forEach((config, topic) => {
      if (!config.pgConfigs) return;

      for (const pgConf of config.pgConfigs) {
        if (pgConf.table && pgConf.table !== table) continue;
        if (pgConf.schema && pgConf.schema !== schema) continue;
        if (pgConf.event !== '*' && pgConf.event !== eventType) continue;
        if (pgConf.filter && record) {
          if (!matchFilter(pgConf.filter, record)) continue;
        }

        ws.send(encodeMessage({
          topic,
          event: 'postgres_changes',
          payload: {
            data: {
              table,
              schema,
              type: eventType,
              columns,
              record: record || null,
              old_record: old_record || null,
              commit_timestamp: new Date().toISOString(),
            },
            ids: [pgConf.id],
          },
          ref: null,
        }));
        break;
      }
    });
  });
}

export function handleJoin(wss, clientSubs, presenceState, send, ws, topic, payload, ref, subs) {
  const config = {};

  if (payload?.config?.postgres_changes) {
    config.pgConfigs = payload.config.postgres_changes.map((pgConfig, index) => ({
      id: index + 1,
      ...pgConfig,
    }));
  }

  if (payload?.config?.presence) {
    config.presenceKey = payload.config.presence.key || null;
  }

  subs.set(topic, config);

  const response = {};
  if (config.presenceKey || topic.includes('presence') || topic.includes('typing') || topic.includes('online')) {
    response.presence_state = getPresenceState(presenceState, topic);
  }

  if (config.pgConfigs) {
    response.postgres_changes = config.pgConfigs;
  }

  send(ws, {
    join_ref: null,
    topic,
    event: 'phx_reply',
    payload: { status: 'ok', response },
    ref,
  });

  send(ws, {
    join_ref: null,
    topic,
    event: 'presence_state',
    payload: response.presence_state || {},
    ref: null,
  });

  send(ws, {
    join_ref: null,
    topic,
    event: 'system',
    payload: { status: 'ok', channel: topic, extension: 'postgres_changes' },
    ref: null,
  });
}

export function handleLeave(wss, clientSubs, presenceState, send, removePresenceFn, ws, topic, ref, subs) {
  const config = subs.get(topic);
  if (config?.presenceKey) {
    removePresenceFn(wss, clientSubs, presenceState, topic, config.presenceKey, ws);
  }
  subs.delete(topic);

  if (ref) {
    send(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
  }
}

export function handlePresenceTrack(wss, clientSubs, presenceState, send, broadcastPresenceDiffFn, ws, topic, payload, ref, subs) {
  const config = subs.get(topic) || {};
  const key = config.presenceKey || payload?.key || 'anon';
  const meta = payload?.payload || payload?.meta || payload || {};

  config.presenceKey = key;
  subs.set(topic, config);

  if (!presenceState.has(topic)) presenceState.set(topic, new Map());
  const topicState = presenceState.get(topic);
  if (!ws.__presenceRefs) ws.__presenceRefs = new Map();
  const phxRef = ws.__presenceRefs.get(topic) || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  ws.__presenceRefs.set(topic, phxRef);

  const existing = topicState.get(key);
  const metas = existing?.metas?.filter((item) => item.phx_ref !== phxRef) || [];
  const trackedMeta = { ...meta, phx_ref: phxRef };
  topicState.set(key, { metas: [...metas, trackedMeta] });

  const diff = {
    joins: { [key]: { metas: [trackedMeta] } },
    leaves: {},
  };
  broadcastPresenceDiffFn(wss, clientSubs, topic, diff);

  if (ref) {
    send(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
  }
}

export function handlePresenceUntrack(wss, clientSubs, presenceState, send, removePresenceFn, ws, topic, ref, subs) {
  const config = subs.get(topic) || {};
  if (config.presenceKey) {
    removePresenceFn(wss, clientSubs, presenceState, topic, config.presenceKey, ws);
  }
  if (ref) {
    send(ws, { topic, event: 'phx_reply', payload: { status: 'ok', response: {} }, ref });
  }
}
