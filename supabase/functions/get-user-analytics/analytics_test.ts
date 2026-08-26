import {
  calculateApprovalRate,
  calculateAttendanceRate,
  collectTags,
} from "./analytics.ts";
import { createAnalyticsHandler } from "./index.ts";

function responseBody(response: Response): Promise<Record<string, string>> {
  return response.json() as Promise<Record<string, string>>;
}

function fakeClientFactory() {
  return () =>
    ({
      auth: {
        getUser: () =>
          Promise.resolve({
            data: { user: { id: "authenticated-user" } },
            error: null,
          }),
      },
    }) as never;
}

function databaseErrorClientFactory() {
  let calls = 0;
  return () => {
    calls += 1;
    if (calls === 1) return fakeClientFactory()();
    return {
      from: () => ({
        select() {
          return this;
        },
        eq: () =>
          Promise.resolve({
            data: null,
            error: new Error("database unavailable"),
          }),
      }),
    } as never;
  };
}

Deno.test("analytics handler answers OPTIONS requests", async () => {
  const response = await createAnalyticsHandler()(
    new Request("https://example.test", { method: "OPTIONS" }),
  );
  if (response.status !== 200 || (await response.text()) !== "ok") {
    throw new Error("Expected OPTIONS to return 200 ok");
  }
});

Deno.test("analytics handler rejects requests without authorization", async () => {
  const response = await createAnalyticsHandler()(
    new Request("https://example.test", { method: "POST" }),
  );
  const body = await responseBody(response);
  if (response.status !== 401 || body.error !== "unauthorized") {
    throw new Error(
      `Expected unauthorized response, got ${response.status} ${
        JSON.stringify(body)
      }`,
    );
  }
});

Deno.test("analytics handler rejects an invalid authorization token", async () => {
  const invalidClientFactory = () =>
    ({
      auth: {
        getUser: () =>
          Promise.resolve({
            data: { user: null },
            error: new Error("invalid token"),
          }),
      },
    }) as never;
  const request = new Request("https://example.test", {
    method: "POST",
    headers: {
      Authorization: "Bearer invalid-token",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ user_id: "target-user", period: "all" }),
  });
  const response = await createAnalyticsHandler(invalidClientFactory)(request);
  const body = await responseBody(response);
  if (response.status !== 401 || body.error !== "unauthorized") {
    throw new Error(
      `Expected unauthorized response, got ${response.status} ${
        JSON.stringify(body)
      }`,
    );
  }
});

Deno.test("analytics handler rejects a missing user id", async () => {
  const request = new Request("https://example.test", {
    method: "POST",
    headers: {
      Authorization: "Bearer test-token",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ period: "all" }),
  });
  const response = await createAnalyticsHandler(fakeClientFactory())(request);
  const body = await responseBody(response);
  if (response.status !== 400 || body.error !== "invalid") {
    throw new Error(
      `Expected invalid response, got ${response.status} ${
        JSON.stringify(body)
      }`,
    );
  }
});

Deno.test("analytics handler rejects an unsupported period", async () => {
  const request = new Request("https://example.test", {
    method: "POST",
    headers: {
      Authorization: "Bearer test-token",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ user_id: "target-user", period: "daily" }),
  });
  const response = await createAnalyticsHandler(fakeClientFactory())(request);
  const body = await responseBody(response);
  if (response.status !== 400 || body.error !== "invalid_period") {
    throw new Error(
      `Expected invalid_period response, got ${response.status} ${
        JSON.stringify(body)
      }`,
    );
  }
});

Deno.test("analytics handler returns 500 when the hosted-events query fails", async () => {
  const request = new Request("https://example.test", {
    method: "POST",
    headers: {
      Authorization: "Bearer test-token",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ user_id: "target-user", period: "all" }),
  });
  const response = await createAnalyticsHandler(databaseErrorClientFactory())(
    request,
  );
  const body = await responseBody(response);
  if (response.status !== 500 || body.error !== "db_error") {
    throw new Error(
      `Expected db_error response, got ${response.status} ${
        JSON.stringify(body)
      }`,
    );
  }
});

Deno.test("attendance rate is 100% when every approved attendee checks in", () => {
  if (calculateAttendanceRate(3, 3) !== 100) {
    throw new Error("Expected attendance rate to be 100%");
  }
});

Deno.test("attendance rate is zero when there are no approved attendees", () => {
  if (calculateAttendanceRate(0, 0) !== 0) {
    throw new Error("Expected attendance rate to be 0%");
  }
});

Deno.test("attendance rate rounds to an integer percentage", () => {
  if (calculateAttendanceRate(2, 3) !== 67) {
    throw new Error("Expected attendance rate to round to 67%");
  }
});

Deno.test("rates handle mixed registration outcomes", () => {
  if (
    calculateApprovalRate(2, 1, 1) !== 50 ||
    calculateAttendanceRate(1, 2) !== 50
  ) {
    throw new Error("Expected mixed registration rates to be 50%");
  }
});

Deno.test("approval rate is 100% when every registration is approved", () => {
  if (calculateApprovalRate(4, 0, 0) !== 100) {
    throw new Error("Expected approval rate to be 100%");
  }
});

Deno.test("approval rate is zero when there are no registrations", () => {
  if (calculateApprovalRate(0, 0, 0) !== 0) {
    throw new Error("Expected approval rate to be 0%");
  }
});

Deno.test("collectTags trims, removes blanks, and deduplicates tags", () => {
  const tags = collectTags([" BBQ, Movie ", null, "Movie, hiking", ""]);
  const expected = ["BBQ", "Movie", "hiking"];
  if (JSON.stringify(tags) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(tags)}`,
    );
  }
});
