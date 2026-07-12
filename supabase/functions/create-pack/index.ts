import {
  adminClient,
  generateInviteToken,
  handleError,
  hashInviteToken,
  inviteExpiry,
  jsonResponse,
  optionalMaxMembers,
  optionsResponse,
  parseObject,
  requireName,
  requirePost,
  requireUser,
} from "../_shared/http.ts";

Deno.serve(async (req) => {
  const preflight = optionsResponse(req);
  if (preflight) return preflight;

  try {
    requirePost(req);
    const user = await requireUser(req);
    const body = await parseObject(req);
    const name = requireName(body.name, "name");
    const displayName = requireName(body.displayName, "displayName");
    const maxMembers = optionalMaxMembers(body.maxMembers);
    const token = generateInviteToken();
    const expiresAt = inviteExpiry();
    const tokenHash = await hashInviteToken(token);

    const { data, error } = await adminClient().rpc("internal_create_pack", {
      p_actor: user.id,
      p_name: name,
      p_display_name: displayName,
      p_max_members: maxMembers,
      p_token_hash: tokenHash,
      p_expires_at: expiresAt,
    }).single();
    if (error) throw error;

    return jsonResponse({
      packId: data.pack_id,
      invite: { token, expiresAt: data.expires_at },
    }, 201);
  } catch (error) {
    return handleError(error);
  }
});
