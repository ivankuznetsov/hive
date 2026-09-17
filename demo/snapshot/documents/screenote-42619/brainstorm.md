## Round 1
### Q1. Screenote currently has screenshot-annotation comment threads, while the idea names task comments and brainstorm/question answers. Which exact screens and message types should the first release cover, and are any of them Hive-owned surfaces that Screenote must integrate with rather than native Screenote records?
### A1.
Cover every native Screenote browser composer where a user can write a task comment or submit an answer to a brainstorm/question prompt, including the existing screenshot-annotation comment thread if it uses the same native comment model. Do not build a separate integration for Hive-owned UIs in the first release; Screenote should attach images to the native comment/answer records it already displays or submits.

### Q2. Should attachment upload and viewing be limited to the browser UI, or must the initial release also support any API, MCP, CLI, or Telegram-authored comments and answers? Please name the required channels.
### A2.
The initial release is browser-UI authoring only. Existing API/MCP/CLI consumers should remain backward compatible and may expose attachment metadata or protected URLs when reading records, but uploading images through API, MCP, CLI, or Telegram is not required yet.

### Q3. Which ways of adding images are required: file picker only, or also drag-and-drop and clipboard paste? The recommended first-release set is all three because screenshots are commonly copied directly to the clipboard.
### A3.
Support all three: file picker, drag-and-drop, and clipboard paste.

### Q4. Do you accept this upload-flow default: upload each image immediately after selection, show per-file progress, block message submission until every selected image has either uploaded successfully or been removed, offer retry/remove on failure, and automatically clean up uploads from abandoned drafts?
### A4.
Yes. Upload immediately after selection, show per-file progress, block submission while any attachment is still uploading, and provide retry/remove on failure. Clean up abandoned draft uploads automatically using a bounded expiry/background cleanup mechanism.

### Q5. Do you accept this initial file policy: PNG, JPEG, and WebP; at most 5 images per message; at most 20 MB per image and 50 MB combined; reject SVG, animated GIF, and HEIC initially? If not, specify the formats and limits you want.
### A5.
Accept that policy for the first release: PNG, JPEG, and WebP; maximum 5 images per message; maximum 20 MB per image and 50 MB combined; reject SVG, animated GIF, and HEIC. Validate actual content/type server-side rather than trusting extensions or browser MIME metadata.

### Q6. After submission, should attachments be immutable with the message, or may the original author add or remove individual images later? If the parent message is deleted, should its attachments always be deleted with it, subject only to any existing audit or retention policy?
### A6.
Attachments are immutable after the message is submitted for the first release; users may edit message text under existing rules but cannot add or remove individual submitted images. Deleting the parent message should delete or schedule deletion of its attachments, subject to any existing soft-delete, audit, or retention policy. Draft attachments removed before submission should be cleaned up promptly.

### Q7. Should attachment visibility exactly inherit access to the parent task/message, with no public or permanent blob URL, and should every attachment retain the message author as its uploader even when an API key or agent submitted it? Note any role-specific exceptions.
### A7.
Yes. Attachment access must exactly inherit the parent task/message authorization. Do not expose public or permanent blob URLs; use authenticated delivery or short-lived signed URLs. Record the human message author as uploader for browser submissions and preserve both actor/credential identity and attributed author for future agent/API submissions. No role-specific visibility exceptions.

### Q8. For rendering, do you accept responsive inline thumbnails plus an accessible modal viewer with full-size display, next/previous controls for multiple images, keyboard navigation, Escape-to-close, and an explicit “open original” action? Note whether download, zoom, captions, or alt-text entry is required in the first release.
### A8.
Accept responsive inline thumbnails and an accessible modal viewer with full-size display, previous/next controls, keyboard navigation, Escape-to-close, and an explicit open-original action. Include zoom and download/open-original in the first release. Alt text is required: allow optional author-entered alt text and fall back to a neutral accessible label such as “Attached image” rather than deriving meaning from the filename. Captions are not required.

### Q9. Where else must attachments appear or be consumable: agent prompt/history context, API/MCP/CLI responses, notifications or email digests, exports, and audit logs? For each required surface, say whether it needs the image itself, a protected link, a thumbnail, or metadata only.
### A9.
Agent prompt/history context and API/MCP/CLI read responses should expose attachment metadata plus an authorized short-lived URL so capable consumers can inspect the image; include alt text, media type, dimensions, and size. Browser notifications and email digests should show metadata and a protected link, not embed the original image. Exports and audit logs need metadata and stable attachment identity only in the first release. Do not place durable public URLs in any surface.

## Requirements

- **Actor:** An authenticated Screenote user may attach images in every native browser composer for task comments and brainstorm/question answers, including screenshot-annotation comments when they use the same native comment model. Hive-owned interfaces and image authoring through API, MCP, CLI, or Telegram are out of scope for the first release.
- **Authorization and ownership:** An attachment belongs to exactly one native comment or answer and its parent task, and records the submitting human as uploader. Attachment visibility exactly inherits the parent task/message authorization; no public or permanent blob URL is exposed.
- **Compose flow:** Users can add images through a file picker, drag-and-drop, or clipboard paste; see previews and per-file upload progress; enter optional alt text; and remove an image before submission. Each image uploads immediately after selection, failed uploads offer retry/remove, and message submission remains blocked while any attachment is uploading or failed.
- **Validation:** Accept PNG, JPEG, and WebP only, with at most 5 images per message, 20 MB per image, and 50 MB combined. Reject SVG, animated GIF, HEIC, invalid content, and misleading extension/MIME combinations using server-side content validation.
- **Submitted state:** Submitting the message permanently associates its successfully uploaded images with that message. Attachments are immutable afterward even when existing rules allow text edits; deleting the parent deletes or schedules deletion of its attachments under existing retention rules.
- **Draft lifecycle:** Removing a draft image cleans it up promptly. Unsubmitted draft uploads expire and are removed automatically by a bounded background-cleanup process.
- **Display:** Submitted messages render responsive inline thumbnails in light and dark themes. Activating a thumbnail opens an accessible full-size viewer with previous/next controls, keyboard navigation, Escape-to-close, zoom, download, and open-original behavior.
- **Accessibility:** Author-entered alt text is rendered when present; otherwise the image uses a neutral accessible label such as “Attached image,” never filename-derived meaning.
- **Other consumers:** Agent prompt/history and API/MCP/CLI reads expose attachment identity, alt text, media type, dimensions, size, and an authorized short-lived URL. Browser notifications and email digests expose metadata plus a protected link; exports and audit logs expose metadata and stable attachment identity only.
- **Acceptance example — successful post:** An authorized user adds multiple valid images through any supported input method, observes independent progress/previews, removes or retries files as needed, submits only after all remaining uploads succeed, and then sees the images on the correct message, task, and author in an accessible viewer.
- **Acceptance example — invalid or incomplete post:** The UI and server reject unsupported, spoofed, oversized, over-count, or over-total selections with actionable feedback; a pending or failed image prevents submission until it succeeds or is removed, without losing the message draft or valid attachments.
- **Acceptance example — access and lifecycle:** A user without access to the parent cannot fetch its attachment or reuse an expired URL; deleting a message and abandoning or removing draft images trigger the specified cleanup without affecting images on other messages.
- **Test coverage:** Cover each composer and input method, upload progress/retry/removal, all validation limits and content spoofing, association and authorization boundaries, draft and parent-deletion cleanup, read-surface payloads, viewer accessibility/keyboard behavior, responsive rendering, and visual states in both light and dark themes.

<!-- COMPLETE -->
