-- Publish the current licence agreement as the single agreement shown to users.
INSERT INTO public.legal_documents (slug, title, content_html, icon, is_published)
VALUES (
  'terms',
  'Договор публичной оферты на заключение лицензионного договора',
  '<p>Перед регистрацией или загрузкой трека ознакомьтесь с полным текстом договора.</p><p><a href="/documents/dogovor-publichnoy-oferty-na-zaklyuchenie-licenzionnogo-dogovora.docx" target="_blank" rel="noopener noreferrer">Открыть договор публичной оферты на заключение лицензионного договора</a></p>',
  'FileText',
  true
)
ON CONFLICT (slug) DO UPDATE
SET title = EXCLUDED.title,
    content_html = EXCLUDED.content_html,
    icon = EXCLUDED.icon,
    is_published = EXCLUDED.is_published,
    updated_at = now();
