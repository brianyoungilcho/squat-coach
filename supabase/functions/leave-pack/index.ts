import {
  adminClient,
  handleError,
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

    const { error } = await adminClient().rpc("internal_leave_pack", {
      p_actor: user.id,
      p_pack_id: packId,
    });
    if (error) throw error;

    return jsonResponse({ left: true });
  } catch (error) {
    return handleError(error);
  }
});
