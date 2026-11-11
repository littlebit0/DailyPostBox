export interface ImapSequenceRange {
  start: number;
  end: number;
}

export function newestFirstSequenceRanges(
  totalMessages: number,
  limit: number | "all",
  firstBatchSize = 25,
  batchSize = 250
): ImapSequenceRange[] {
  if (!Number.isSafeInteger(totalMessages) || totalMessages < 0) {
    throw new RangeError("totalMessages must be a non-negative integer");
  }
  if (limit !== "all" && (!Number.isSafeInteger(limit) || limit < 0)) {
    throw new RangeError("limit must be a non-negative integer or all");
  }
  if (!Number.isSafeInteger(firstBatchSize) || firstBatchSize <= 0) {
    throw new RangeError("firstBatchSize must be a positive integer");
  }
  if (!Number.isSafeInteger(batchSize) || batchSize <= 0) {
    throw new RangeError("batchSize must be a positive integer");
  }

  let remaining = limit === "all"
    ? totalMessages
    : Math.min(totalMessages, limit);
  let end = totalMessages;
  const ranges: ImapSequenceRange[] = [];

  while (remaining > 0) {
    const maximumBatchSize = ranges.length === 0 ? firstBatchSize : batchSize;
    const currentBatchSize = Math.min(remaining, maximumBatchSize);
    const start = end - currentBatchSize + 1;
    ranges.push({ start, end });
    remaining -= currentBatchSize;
    end = start - 1;
  }

  return ranges;
}

// UIDs stay stable when other clients expunge messages between batch
// connections, unlike sequence numbers.
export function newestFirstUidBatches(
  uids: readonly number[],
  limit: number | "all",
  firstBatchSize = 25,
  batchSize = 250
): number[][] {
  const sorted = [...uids].sort((left, right) => left - right);
  return newestFirstSequenceRanges(
    sorted.length,
    limit,
    firstBatchSize,
    batchSize
  ).map((range) => sorted.slice(range.start - 1, range.end));
}

// Only "all" imports snapshot every UID; finite fetches (including the
// single-message IDLE path) search just the newest sequence range.
export function latestUidSearchQuery(
  totalMessages: number,
  limit: number | "all"
): { all: true } | { seq: string } | null {
  if (totalMessages <= 0 || limit === 0) return null;
  if (limit === "all") return { all: true };
  return { seq: `${Math.max(1, totalMessages - limit + 1)}:*` };
}
