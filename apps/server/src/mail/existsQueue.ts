// Turns IMAP EXISTS notifications into fetches of every newly arrived
// message. A notification that arrives while a fetch is running is queued,
// not dropped, and a jump of several messages fetches all of them.
export function createExistsQueue<T>(options: {
  fetchNewest: (count: number) => Promise<T[]>;
  onMessage: (message: T) => Promise<void>;
  onError: (error: unknown) => void;
  isStopped: () => boolean;
}): (event: { count: number; prevCount: number }) => Promise<void> {
  let pending = 0;
  let running: Promise<void> | undefined;

  const drain = async (): Promise<void> => {
    try {
      while (pending > 0 && !options.isStopped()) {
        const count = pending;
        pending = 0;
        for (const message of await options.fetchNewest(count)) {
          await options.onMessage(message);
        }
      }
    } catch (error) {
      options.onError(error);
    } finally {
      running = undefined;
    }
  };

  return (event) => {
    if (options.isStopped()) return Promise.resolve();
    pending += Math.max(1, event.count - event.prevCount);
    running ??= drain();
    return running;
  };
}
