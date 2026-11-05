interface Resource {
  id: string;
  type: string;
  attributes?: Record<string, unknown>;
  relationships?: Record<string, { data: { id: string; type: string } | { id: string; type: string }[] | null }>;
}

interface IdentityDocument {
  data: Resource;
  included?: Resource[];
}

export function parseMembership(
  document: unknown,
  campaignId: string,
  ownerUserId: string,
): { userId: string; plus: boolean } {
  const { data, included = [] } = document as IdentityDocument;
  const memberships = data.relationships?.memberships?.data;
  const ids = new Set((Array.isArray(memberships) ? memberships : []).map((link) => link.id));

  // Patreon lists no membership for a creator on their own campaign.
  const plus = data.id === ownerUserId || included.some((member) => {
    const campaign = member.relationships?.campaign?.data;
    const cents = member.attributes?.currently_entitled_amount_cents;
    return (
      member.type === "member" &&
      ids.has(member.id) &&
      member.attributes?.patron_status === "active_patron" &&
      !Array.isArray(campaign) &&
      campaign?.id === campaignId &&
      typeof cents === "number" &&
      cents > 0
    );
  });
  return { userId: data.id, plus };
}
