import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  calculateApprovalRate,
  calculateAttendanceRate,
  collectTags,
} from "./analytics.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function rangeStart(period: string): string | null {
  const days = period === "weekly" ? 7 : period === "monthly" ? 30 : 0;
  if (days === 0) return null;
  return new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
}

type ClientFactory = (
  url: string,
  key: string,
  options?: Record<string, unknown>,
) => SupabaseClient;

export function createAnalyticsHandler(
  clientFactory: ClientFactory = createClient as unknown as ClientFactory,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }

    try {
      const authHeader = req.headers.get("Authorization");
      if (!authHeader) {
        return jsonResponse({
          error: "unauthorized",
          message: "Missing authorization header",
        }, 401);
      }

      const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
      const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
      const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

      const userClient = clientFactory(supabaseUrl, anonKey, {
        global: { headers: { Authorization: authHeader } },
      });

      const {
        data: { user },
        error: authError,
      } = await userClient.auth.getUser();

      if (authError || !user) {
        return jsonResponse({
          error: "unauthorized",
          message: "Invalid or expired token",
        }, 401);
      }

      const body = (await req.json()) as { user_id?: string; period?: string };
      const targetUserId = body.user_id;
      const period = body.period ?? "all";

      if (!targetUserId) {
        return jsonResponse({
          error: "invalid",
          message: "user_id is required",
        }, 400);
      }

      if (!["weekly", "monthly", "all"].includes(period)) {
        return jsonResponse({
          error: "invalid_period",
          message: "period must be 'weekly', 'monthly', or 'all'",
        }, 400);
      }

      const serviceClient = clientFactory(supabaseUrl, serviceRoleKey);
      const since = rangeStart(period);

      // --- 主辦人維度：該用戶作為 creator 發起的活動（可選時間範圍過濾） ---
      let hostedEventsQuery = serviceClient
        .from("events")
        .select("id, event_type")
        .eq("creator_id", targetUserId);

      if (since) {
        hostedEventsQuery = hostedEventsQuery.gte("start_time", since).lte(
          "start_time",
          new Date().toISOString(),
        );
      }

      const { data: hostedEvents, error: hostedError } =
        await hostedEventsQuery;

      if (hostedError) {
        console.error("get-user-analytics hostedEvents error", hostedError);
        return jsonResponse(
          { error: "db_error", message: hostedError.message },
          500,
        );
      }

      const hostedEventIds = (hostedEvents ?? []).map((e) => e.id);
      const hostedEventsCount = hostedEventIds.length;

      // 主辦活動涵蓋標籤（event_type 去重）
      const hostedTags = collectTags(
        (hostedEvents ?? []).map((e) => e.event_type),
      );

      // --- 報名與轉化（限主辦活動） ---
      let totalRegistrations = 0;
      let totalApproved = 0;
      let totalRejected = 0;
      let totalPending = 0;
      let waitlistConversions = 0;
      let checkedInRegistrations = 0;

      if (hostedEventIds.length > 0) {
        const { count: regCount, error: regError } = await serviceClient
          .from("event_registrations")
          .select("id", { count: "exact", head: true })
          .in("event_id", hostedEventIds);

        if (regError) {
          return jsonResponse(
            { error: "db_error", message: regError.message },
            500,
          );
        }

        const { count: approvedCount, error: approvedError } =
          await serviceClient
            .from("event_registrations")
            .select("id", { count: "exact", head: true })
            .in("event_id", hostedEventIds)
            .eq("status", "approved");

        if (approvedError) {
          return jsonResponse({
            error: "db_error",
            message: approvedError.message,
          }, 500);
        }

        const { count: rejectedCount, error: rejectedError } =
          await serviceClient
            .from("event_registrations")
            .select("id", { count: "exact", head: true })
            .in("event_id", hostedEventIds)
            .eq("status", "rejected");

        if (rejectedError) {
          return jsonResponse({
            error: "db_error",
            message: rejectedError.message,
          }, 500);
        }

        const { count: pendingCount, error: pendingError } = await serviceClient
          .from("event_registrations")
          .select("id", { count: "exact", head: true })
          .in("event_id", hostedEventIds)
          .eq("status", "pending");

        if (pendingError) {
          return jsonResponse({
            error: "db_error",
            message: pendingError.message,
          }, 500);
        }

        const { count: waitlistConvCount, error: wlConvError } =
          await serviceClient
            .from("event_registrations")
            .select("id", { count: "exact", head: true })
            .in("event_id", hostedEventIds)
            .not("waitlist_converted_at", "is", null);

        if (wlConvError) {
          return jsonResponse({
            error: "db_error",
            message: wlConvError.message,
          }, 500);
        }

        const { count: checkedInCount, error: checkedInError } =
          await serviceClient
            .from("event_registrations")
            .select("id", { count: "exact", head: true })
            .in("event_id", hostedEventIds)
            .not("checked_in_at", "is", null);

        if (checkedInError) {
          return jsonResponse({
            error: "db_error",
            message: checkedInError.message,
          }, 500);
        }

        totalRegistrations = regCount ?? 0;
        totalApproved = approvedCount ?? 0;
        totalRejected = rejectedCount ?? 0;
        totalPending = pendingCount ?? 0;
        waitlistConversions = waitlistConvCount ?? 0;
        checkedInRegistrations = checkedInCount ?? 0;
      }

      // 核准率：Approved / (Approved + Rejected + Pending)
      const approvalRate = calculateApprovalRate(
        totalApproved,
        totalRejected,
        totalPending,
      );

      // 出席率：Checked-in / Approved
      const attendanceRate = calculateAttendanceRate(
        checkedInRegistrations,
        totalApproved,
      );

      // --- 參與者維度：該用戶作為參與者的核准 / 實際簽到活動數 ---
      let effectiveEventScope: string[] | null = null;
      if (since) {
        const { data: inRangeEvents, error: rangeError } = await serviceClient
          .from("events")
          .select("id")
          .gte("start_time", since)
          .lte("start_time", new Date().toISOString());

        if (rangeError) {
          return jsonResponse({
            error: "db_error",
            message: rangeError.message,
          }, 500);
        }

        effectiveEventScope = (inRangeEvents ?? []).map((e) => e.id);
      }

      let participatedQuery = serviceClient
        .from("event_registrations")
        .select("event_id", { count: "exact", head: true })
        .eq("profile_id", targetUserId)
        .eq("status", "approved")
        .not("checked_in_at", "is", null);

      let approvedParticipationsQuery = serviceClient
        .from("event_registrations")
        .select("event_id", { count: "exact", head: true })
        .eq("profile_id", targetUserId)
        .eq("status", "approved");

      if (effectiveEventScope !== null) {
        if (effectiveEventScope.length > 0) {
          participatedQuery = participatedQuery.in(
            "event_id",
            effectiveEventScope,
          );
          approvedParticipationsQuery = approvedParticipationsQuery.in(
            "event_id",
            effectiveEventScope,
          );
        } else {
          const stats = await buildStats(
            serviceClient,
            targetUserId,
            hostedEventsCount,
            hostedTags,
            totalRegistrations,
            totalApproved,
            approvalRate,
            waitlistConversions,
            checkedInRegistrations,
            attendanceRate,
            0,
            0,
            [],
          );
          return jsonResponse({
            success: true,
            user_id: targetUserId,
            period,
            stats,
          }, 200);
        }
      }

      const { count: eventsParticipated, error: participatedError } =
        await participatedQuery;
      if (participatedError) {
        return jsonResponse({
          error: "db_error",
          message: participatedError.message,
        }, 500);
      }

      const { count: approvedParticipations, error: approvedPartError } =
        await approvedParticipationsQuery;
      if (approvedPartError) {
        return jsonResponse({
          error: "db_error",
          message: approvedPartError.message,
        }, 500);
      }

      // --- 社群信用：加權信譽積分 + 被檢舉頻率 ---
      const reputationGained = await computeWeightedReputation(
        serviceClient,
        targetUserId,
      );
      const reportCount = await computeReportCount(serviceClient, targetUserId);

      // --- 探索標籤：該用戶參與（核准且簽到）活動的 event_type 去重 ---
      const exploredTags = await computeExploredTags(
        serviceClient,
        targetUserId,
        effectiveEventScope,
      );

      const stats = {
        hostedEvents: hostedEventsCount,
        hostedTags,
        totalRegistrations,
        totalApproved,
        approvalRate,
        waitlistConversions,
        checkedInRegistrations,
        attendanceRate,
        eventsParticipated: eventsParticipated ?? 0,
        approvedParticipations: approvedParticipations ?? 0,
        reputationGained,
        reportCount,
        exploredTags,
      };

      return jsonResponse({
        success: true,
        user_id: targetUserId,
        period,
        stats,
      }, 200);
    } catch (err) {
      console.error("get-user-analytics unexpected error", err);
      return jsonResponse({
        error: "internal",
        message: "Internal server error",
      }, 500);
    }
  };
}

if (import.meta.main) {
  Deno.serve(createAnalyticsHandler());
}

async function buildStats(
  serviceClient: SupabaseClient,
  targetUserId: string,
  hostedEvents: number,
  hostedTags: string[],
  totalRegistrations: number,
  totalApproved: number,
  approvalRate: number,
  waitlistConversions: number,
  checkedInRegistrations: number,
  attendanceRate: number,
  eventsParticipated: number,
  approvedParticipations: number,
  exploredTags: string[],
) {
  const reputationGained = await computeWeightedReputation(
    serviceClient,
    targetUserId,
  );
  const reportCount = await computeReportCount(serviceClient, targetUserId);

  return {
    hostedEvents,
    hostedTags,
    totalRegistrations,
    totalApproved,
    approvalRate,
    waitlistConversions,
    checkedInRegistrations,
    attendanceRate,
    eventsParticipated,
    approvedParticipations,
    reputationGained,
    reportCount,
    exploredTags,
  };
}

// 加權信譽積分：一般用戶推薦 = score_increment * 1.0；venue_approved 官方場地方 = 1.5
async function computeWeightedReputation(
  serviceClient: SupabaseClient,
  targetUserId: string,
): Promise<number> {
  const { data: recommendations, error } = await serviceClient
    .from("recommendations")
    .select("score_increment, from_profile:profiles(role_status)")
    .eq("to_profile_id", targetUserId);

  if (error) {
    console.error("get-user-analytics recommendations error", error);
    return 0;
  }

  return (recommendations ?? []).reduce((sum, r) => {
    const role = r.from_profile?.[0]?.role_status as string | undefined;
    const weight = role === "venue_approved" ? 1.5 : 1.0;
    return sum + Math.ceil((r.score_increment ?? 0) * weight);
  }, 0);
}

// 被檢舉頻率：reports 表中 target_profile_id = 該用戶 的數量
async function computeReportCount(
  serviceClient: SupabaseClient,
  targetUserId: string,
): Promise<number> {
  const { count, error } = await serviceClient
    .from("reports")
    .select("id", { count: "exact", head: true })
    .eq("target_profile_id", targetUserId);

  if (error) {
    console.error("get-user-analytics reportCount error", error);
    return 0;
  }

  return count ?? 0;
}

async function computeExploredTags(
  serviceClient: SupabaseClient,
  targetUserId: string,
  effectiveEventScope: string[] | null,
): Promise<string[]> {
  let query = serviceClient
    .from("event_registrations")
    .select("event_id, events(event_type)")
    .eq("profile_id", targetUserId)
    .eq("status", "approved")
    .not("checked_in_at", "is", null);

  if (effectiveEventScope !== null && effectiveEventScope.length > 0) {
    query = query.in("event_id", effectiveEventScope);
  }

  const { data, error } = await query;
  if (error) {
    console.error("get-user-analytics exploredTags error", error);
    return [];
  }

  return collectTags(
    (data ?? []).map((row: { events: { event_type: string }[] }) => {
      const event = row.events?.[0] ?? null;
      return event?.event_type ?? null;
    }),
  );
}
