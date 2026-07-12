import {
  adminClient,
  handleError,
  hashInviteToken,
  jsonResponse,
  optionsResponse,
  parseObject,
  requireInviteToken,
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
    const token = requireInviteToken(body.token);
    const displayName = requireName(body.displayName, "displayName");
    const tokenHash = await hashInviteToken(token);

    const { data, error } = await adminClient().rpc("internal_join_pack", {
      p_actor: user.id,
      p_display_name: displayName,
      p_token_hash: tokenHash,
    }).single();
    if (error) throw error;

    return jsonResponse({ packId: data.pack_id, name: data.pack_name });
  } catch (error) {
    return handleError(error);
  }
});
