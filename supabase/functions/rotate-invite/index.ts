import {
  adminClient,
  generateInviteToken,
  handleError,
  hashInviteToken,
  inviteExpiry,
  jsonResponse,
  optionsResponse,
  parseObject,
  requirePost,
  requireUser,
  requireUuid,
} from "../_shared/http.ts";

Deno.serve(async (req) => {
  const preflight = optionsResponse(req);
  if (preflight) return preflight;

  try {
    requirePost(req);
    const user = await requireUser(req);
    const body = await parseObject(req);
    const packId = requireUuid(body.packId, "packId");
    const token = generateInviteToken();
    const expiresAt = inviteExpiry();
    const tokenHash = await hashInviteToken(token);

    const { data, error } = await adminClient().rpc("internal_rotate_invite", {
      p_actor: user.id,
      p_pack_id: packId,
      p_token_hash: tokenHash,
      p_expires_at: expiresAt,
    }).single();
    if (error) throw error;

    return jsonResponse({ token, expiresAt: data.expires_at });
  } catch (error) {
    return handleError(error);
  }
});
