# Data Model Draft

## users

- id
- email
- display_name
- created_at

## mail_accounts

- id
- user_id
- provider_id
- email_address
- display_name
- auth_mode
- incoming_protocol
- encrypted_secret_ref
- connection_override_json
- sync_status
- last_error
- created_at
- updated_at

## mailboxes

- id
- account_id
- provider_mailbox_id
- name
- role: inbox | sent | drafts | trash | spam | archive | custom
- created_at

## messages

- id
- account_id
- mailbox_id
- provider_message_id
- thread_id
- from_address
- to_addresses_json
- cc_addresses_json
- subject
- snippet
- text_body_ref
- html_body_ref
- received_at
- sent_at
- has_attachments
- flags_json
- created_at

Unique key: `account_id + mailbox_id + provider_message_id`

## attachments

- id
- message_id
- filename
- content_type
- size_bytes
- storage_key
- scan_status
- created_at

## sync_cursors

- id
- account_id
- mailbox_id
- cursor_type: imap_uidvalidity | imap_uid | pop3_uidl | history_id
- cursor_value
- updated_at

## device_push_tokens

- id
- user_id
- platform: ios | android | macos | windows | web
- token
- enabled
- created_at
- updated_at

## outbound_messages

- id
- account_id
- status: queued | sending | sent | failed
- draft_json
- provider_message_id
- error
- created_at
- sent_at
