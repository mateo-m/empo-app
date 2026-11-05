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
  const find = (type: string, id: string) =>
    included.find((resource) => resource.type === type && resource.id === id);
  const related = (resource: Resource, name: string) => {
    const link = resource.relationships?.[name]?.data;
    return link == null ? [] : Array.isArray(link) ? link : [link];
  };

  // Patreon lists no membership for a creator on their own campaign.
  const plus = data.id === ownerUserId || related(data, "memberships")
    .map((link) => find("member", link.id))
    .some(
      (member) =>
        member !== undefined &&
        member.attributes?.patron_status === "active_patron" &&
        related(member, "campaign")[0]?.id === campaignId &&
        related(member, "currently_entitled_tiers").some((link) => {
          const cents = find("tier", link.id)?.attributes?.amount_cents;
          return typeof cents === "number" && cents > 0;
        }),
    );
  return { userId: data.id, plus };
}
