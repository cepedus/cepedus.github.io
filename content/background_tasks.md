---
title: Framework-agnostic background task management
date: 2024-04-01
description: Simple background queuing for long I/O tasks.
tags:
  - blog
  - python
  - asyncio
---

## Context

You're building an API and some of your treated requests are expected to incur into a long processing time. In order not to timeout your server, you choose to go with a pattern of the likes: your endpoint has 3 response types

- Result not ready ⏳
- Here's the result 🫡
- Error during processing 😬

A typical (and very simplified) "happy path" is the following:

1. Incoming request $R$
2. Launch calculation in the background with some kind of job state monitoring $J_R$
3. Immediate response "job was taken into account"
4. Incoming same request $R$ either waits for $J_R$ or fetchs its result

## Options

There are already off-the-shelf solutions out there such as [FastAPI Background Tasks](https://fastapi.tiangolo.com/tutorial/background-tasks/), but some use-cases need to return the response _after_ creating the job (because there's extra validation to do, some intermediate processing, etc.)

Sometimes the processing job you need is ~~thicc~~ heavy to compute and you need a classical distributed computing stack (Spark, Dask, Ray and friends). Some references:

- [article] A survey on the Distributed Computing stack ([DOI link](https://doi.org/10.1016/j.cosrev.2021.100422))
- [wiki] [Distributed computing](https://en.wikipedia.org/wiki/Distributed_computing)
- [repo] [donnemartin/system-design-primer](https://github.com/donnemartin/system-design-primer)

But sometimes your processing job is not _that_ heavy and the server could perfectly handle it without putting in peril your p99 response time. Or maybe, you choose to beef up your server instead of adding another component to your technical stack (installation, monitoring, maintenance not worth it).

In those cases, how to proceed? The approach I present focuses on I/O-heavy tasks, for CPU-heavy ones we would need to introduce a [`ProcessPoolExecutor`](https://docs.python.org/3/library/concurrent.futures.html#processpoolexecutor) and attach it to the state of our app, for example.

## Approach

At the core, what we're trying to solve is the following problem:

- The server receives long-to-compute requests
- We need to launch and track background tasks
- We need to limit the amount of tasks in order not to overcharge the server
- A failing task will not be handled by our mechanism, the tasks' states are handled elsewhere (retry/renew logic)
- Using as few dependencies as possible

We'll do that by defining:

- `run_background_task(coroutine: Coroutine[Any, Any, Any], task_name: str) -> None` that will enqueue `coroutine` to run on the background.
- `wait_for_task(task_name: str, seconds: int) -> None` that waits for an existing running task and raises a `TimeoutError` if necessary.

`task_name` can be mapped to the task triggering request we receive. This way your endpoint could look something like:

```python
class FooRequest(BaseModel):
    request_id: str
    data: bytes

class BarResponse(BaseModel):
    data: bytes

# TODO on the specific use-case
#   StatusValue(Enum)
#   generate_id(request: FooRequest) -> str
#   get_status(request: FooRequest) -> StatusValue
#   fetch_task_result(request: FooRequest) -> BarResponse
#   retry_logic(request: FooRequest) -> BarResponse
#   acknowledge_response(request: FooRequest) -> BarResponse
#   default_response(request: FooRequest) -> BarResponse
#   default_timeout: int

@app.post("/long-compute/")
async def long_compute(request: FooRequest) -> BarResponse:
    task_name = generate_id(request)
    match get_status(request):
        case StatusValue.RUNNING:
            await wait_for_task(task_name, default_timeout)
            return fetch_task_result(task_name)
        case StatusValue.FAILED:
            return await retry_logic(request)
        case StatusValue.NEW:
            await run_background_task(compute_coroutine(request), task_name)
            return acknowledge_response(request)
        case _:
            return default_response(request)

```

Let's go then step by step:

### Dependencies

We'll keep it as vanilla as possible:

```python
import asyncio
import traceback
from typing import Any, Coroutine, Set

from your_awesome_package.logging import logger
```

The only real constraint is that your `logger` **must be** asynchronous and thread-safe. Check out loguru for an [alternative](https://loguru.readthedocs.io/en/stable/overview.html#asynchronous-thread-safe-multiprocess-safe).

### Concurrency limiting

We can achieve this using a simple Semaphore and a Set for ongoing tasks tracking.

```python
MAX_BACKGROUND_TASKS = 1

_TASKS_SEMAPHORE: asyncio.Semaphore | None = None
_ACTIVE_TASKS: Set[asyncio.Task] = set()


def get_tasks_semaphore() -> asyncio.Semaphore:
    global _TASKS_SEMAPHORE
    if _TASKS_SEMAPHORE is None:
        _TASKS_SEMAPHORE = asyncio.Semaphore(MAX_BACKGROUND_TASKS)
    return _TASKS_SEMAPHORE
```

We include a global getter instead of a direct instantiation of the Semaphore because we don't want to finish in a different event loop from the server.

### `wait_for_task` and `run_background_task`

Now for the interesting part

Using the task-tracking Set we can wait until completion

```python
async def wait_for_task(task_name: str, seconds: int) -> None:
    """Attempts to wait for a task specified by its name.
    - If the task is already finished, nothing happens.
    - If the task finishes before `TASK_TIMEOUT_SECONDS`, nothing happens.
    - If the task continues after `TASK_TIMEOUT_SECONDS`, raises `asyncio.TimeoutError`
    """
    for task in _ACTIVE_TASKS.copy():
        if task.get_name() == task_name:
            logger.info(
                f'[TASKS] Task named "{task_name}" is already scheduled. Waiting for'
                f" {seconds} seconds until completion."
            )
            await asyncio.wait_for(task, timeout=seconds)
```

and define a "send task" coroutine using the global Semaphore:

```python
async def _run_behind_semaphore(coroutine: Coroutine[Any, Any, Any], task_name: str) -> None:
    logger.debug(f'[TASKS] Waiting to run task "{task_name}" on background.')
    async with get_tasks_semaphore():
        logger.info(f'[TASKS] Running task "{task_name}" on background.')
        await coroutine
        logger.debug(f'[TASKS] Finished running task "{task_name}".')
```

We want to recover potential errors on the tasks so we include a logging callback. We don't re-raise as the status is handled elsewhere and we don't want to break the event loop:

```python
def _raise_aware_task_callback(task: asyncio.Task) -> None:
    try:
        task.result()
    # CancelledError inherits from BaseException, not Exception
    except BaseException as e:
        logger.warning(
            f'[TASKS] Task named "{task.get_name()}" raised {repr(e)}:\n\n{traceback.format_exc()}'
        )
```

And finally, the scheduler coroutine. Here's the mechanism to track ongoing jobs, send behind the semaphore and log errors:

```python
async def run_background_task(coroutine: Coroutine[Any, Any, Any], task_name: str) -> None:
    """Launches a coroutine as an `asyncio.Task` in a semaphored-queue manner:
    - Only `MAX_BACKGROUND_TASKS` will be concurrently awaited.
    - Repeated call of this function will execute tasks in the same order they were added.
    """
    task = asyncio.create_task(
        _run_behind_semaphore(coroutine=coroutine, task_name=task_name), name=task_name
    )
    _ACTIVE_TASKS.add(task)
    task.add_done_callback(_ACTIVE_TASKS.discard)
    task.add_done_callback(_raise_aware_task_callback)
    logger.info(
        f'[TASKS] Added task "{task_name}" behind semaphore. Currently {len(_ACTIVE_TASKS)} queued'
        " tasks."
    )
```

## Summary

Taking again our problem-to-solve wishlist:

- The server receives long-to-compute requests ➡️ Any asynchronous framework should suffice (FastAPI, Flask > 2.0, etc.)
- We need to launch and track background tasks ➡️ `run_background_task`
- We need to limit the amount of tasks in order not to overcharge the server ➡️ `_TASKS_SEMAPHORE`
- A failing task will not be handled by our mechanism, the tasks' states are handled elsewhere (retry/renew logic) ✅
- Using as few dependencies as possible ✅ (modulo a decent logging library)

Why bother doing this? I found it extremely fun and stimulating, and I needed a lightweight task scheduling mechanism 😅

<details>
<summary>Full .py module</summary>

```python
import asyncio
import traceback
from typing import Any, Coroutine, Set

from utils.logging import logger

MAX_BACKGROUND_TASKS = 1

_TASKS_SEMAPHORE: asyncio.Semaphore | None = None
_ACTIVE_TASKS: Set[asyncio.Task] = set()


def get_tasks_semaphore() -> asyncio.Semaphore:
    global _TASKS_SEMAPHORE
    if _TASKS_SEMAPHORE is None:
        _TASKS_SEMAPHORE = asyncio.Semaphore(MAX_BACKGROUND_TASKS)
    return _TASKS_SEMAPHORE


async def wait_for_task(task_name: str, seconds: int) -> None:
    """Attempts to wait for a task specified by its name.
    - If the task is already finished, nothing happens.
    - If the task finishes before `TASK_TIMEOUT_SECONDS`, nothing happens.
    - If the task continues after `TASK_TIMEOUT_SECONDS`, raises `asyncio.TimeoutError`
    """
    for task in _ACTIVE_TASKS.copy():
        if task.get_name() == task_name:
            logger.info(
                f'[TASKS] Task named "{task_name}" is already scheduled. Waiting for'
                f" {seconds} seconds until completion."
            )
            await asyncio.wait_for(task, timeout=seconds)


def _raise_aware_task_callback(task: asyncio.Task) -> None:
    try:
        task.result()
    # CancelledError inherits from BaseException, not Exception
    except BaseException as e:  # pylint: disable=broad-except
        logger.warning(
            f'[TASKS] Task named "{task.get_name()}" raised {repr(e)}:\n\n{traceback.format_exc()}'
        )


async def run_background_task(coroutine: Coroutine[Any, Any, Any], task_name: str) -> None:
    """Launches a coroutine as an `asyncio.Task` in a semaphored-queue manner:
    - Only `MAX_BACKGROUND_TASKS` will be concurrently awaited.
    - Repeated call of this function will execute tasks in the same order they were added.
    """
    task = asyncio.create_task(
        _run_behind_semaphore(coroutine=coroutine, task_name=task_name), name=task_name
    )
    _ACTIVE_TASKS.add(task)
    task.add_done_callback(_ACTIVE_TASKS.discard)
    task.add_done_callback(_raise_aware_task_callback)
    logger.info(
        f'[TASKS] Added task "{task_name}" behind semaphore. Currently {len(_ACTIVE_TASKS)} queued'
        " tasks."
    )


async def _run_behind_semaphore(coroutine: Coroutine[Any, Any, Any], task_name: str) -> None:
    logger.info(f'[TASKS] Waiting to run task "{task_name}" on background.')
    async with get_tasks_semaphore():
        logger.info(f'[TASKS] Running task "{task_name}" on background.')
        await coroutine
        logger.info(f'[TASKS] Finished running task "{task_name}".')

```

</details>
