---
name: benchmark-sweeper
description: Use when orchestrating experiment sets, benchmark sweeps, A/B tests, or research runs that need reproducible setup, GPU/process hygiene, command logging, metric extraction, and concise result tables.
---

# Benchmark Sweeper

Use this skill for benchmark runs, A/B comparisons, regression checks, and research sweeps. 

## Output directory
Use workspace directory , or the directory that user specifices as the root dir of running experiment/benchmark sweeps and record result.
Take a general look of the user inqury and name it sweep_<proj_name>.md 
This will be the file that you are going to be working on afterwards.

## Environment

- Record repo path, branch, commit, Python/env path, model/config path, dataset, sample size, batch/concurrency, and date.
- For baselines, use a clean checkout or known commit. Do not infer a baseline from a modified tree unless the user explicitly asks.
- Keep benchmark scripts unchanged unless the task is to change benchmarking itself.
- Put raw outputs under a timestamped result root, with logs beside the artifacts.
- Treat result markdown/notes as local artifacts unless the user explicitly asks to commit them.

For the python path, if you find missing import, it's always helpful to check the README of the repo/tool you are working on to see the environment download guide.

## Command

For every experiment cell, save the exact command:
Note again that for the baseline command try to follow the instructions in baseline repo as much as possible, try not to infer.

```bash
CUDA_VISIBLE_DEVICES=<ids> <python> -m <module> \
  --config <config> \
  --output-dir <result_dir> \
  <sweep flags> \
  <other flags>
```

## GPU And Process Policy

- Check active GPU processes before starting: `nvidia-smi`.
- Use only the GPUs requested or available for the task; document mapping of server/run to GPU.
- If an experiment:
    uses 1 GPU, you can use 2 GPU to start 2 concurrency experiment to improve efficiency.
    uses 2 GPUS, just use 2 gpu to run experiment (experiment concurrency be 1) If you have a pending task that's task1: 1GPU task2: 2GPU, if there's enough GPU you are allowed to use them concurrently
    uses more than 2 GPU, 1 concurrency in total. If more than 4 GPUs, stop and warn user, while providing the essential context.
- After each run, stop servers you started and verify ports/processes/GPU memory are clear.
- If a run fails, keep logs and record the exact failure; do not fill tables with guessed numbers.


## Queue and sweep
Now, after decomposing user's intent, you should have a list of command to run, record them in sweep_<proj_name>.md 
Also record:

- setup/server command and port, if any
- run/generation/eval command
- post-processing command
- environment variables
- any deviation from the planned command

Then, following the gpu policy, choose the next 1-2 element in the list to run.
Note clearly, that is this command a baseline? or a variant/ablation? which variable does it take if not baseline? It should be recorded concisely, both, better in the title of the single command section, and/or in the description.

## Polling
Every time you run a command make sure the running log is visible to you so it's debuggable. Don't put it into a sandbox where you can't see any logs of it (such as logs of server and infernce)
NOTE that always remember to set timeout for youself so that you can poll the status (better be 300s) of the experiment. If the experiment is really long, you can extend an appropriate amount of time. It's not setting timeout for experiement-- just setting timeout for yourself so you can make sure the experiment does not stall there forever.
Each time you are waken up to check the process of the running experiment, always check log and GPU utilization. If they both stall, don't hesitate and inspect why instead of sleeping for another 300s. When nessecary just kill the process, inspect the log, and maybe resatart.

## Full-GPU policy
Since you are in a docker a lot of times, when you nvidia-smi, you can't see the process outside of the docker, so if there's memory and utilization on GPUs and you can't nvidia-smi to see it-- don't panic, they are likely be process outside of this docker.

When you can't find 1 empty GPU in the server you are in, wait for 300s, then nvidia-smi again, and do it for 5 times. If always not enough GPU, don't force-start a process on a busy GPU, instead, organize what you've done, and add the situation(full cpu) in sweep_<proj_name>.md , stop and report.

## Result collection and error handling

As you proceed the experiment sweep, you should be on the way of producing compact tables that match the experiment shape. Rows are variants/cells; columns are fixed axes plus metrics.

Generic shape:

```markdown
## <Experiment Group>

| Variant | Axis 1 | Axis 2 | Completed | Failed | Metric A | Metric B | Metric C | Notes |
|---|---|---|---:|---:|---:|---:|---:|---|
| baseline | ... | ... | ... | ... | ... | ... | ... | ... |
| experiment | ... | ... | ... | ... | ... | ... | ... | ... |
```

Include a short provenance block above the tables:

- result root(s)
- baseline source commit
- experimental source commit
- command deviations
- known caveats

Also if the output is more than/different from table, such as visualizations, graphs, complicated data relationship, trust your intellegence to store the value of the sweep in the sweep_<proj_name>.md we've been working on. 

### Error handling
But after every run finishes, check the result, ask your self: does the result make sense. For example, a 0.1 toks does not really make sense generally. A 1000 WER for an audio model does not make sense. It does not equal to your experiment does not match your expectation, it only triggers when the result is absurd.
Reflect on this: do you think a re-run will make the result get normal? This rerun includes modifying command, or modifying code that makes sense--- again, be 10000% cautious when you are modifying baseline code.
If so, rerun the command, if not(it's an inherent issue/the absurd value actually make sense...), proceed to the next command.
Don't rerun the experiment too many times-- don't get stuck on one experiment.
If you trigger this error handling session, note what you saw, and what you think, concisely, under the corresponding command line section in sweep_<proj_name>.md


## Sumarize, and error handling once more
Check all the result once more. If you find absurd inconcistency, get back to the error handling loop above.

Once you are done with every single command in the queue, look back at all the experiment result, you should be able to draw some conclusion-- what does the result mean? If you think this sweep is hard to draw such conclusion you can skip this step, otherwise make a conclusion (performance improvement?Better agorithm found? Key issue revealed in the ablation? And so)

## Expected Output 
```markdown
## Overview
A concise description of this whole task

## Environment/setup
Include as instructed above in the Environment section

## Command list
### <command_1_name>
Include everything instructed above from the command formation to error handling, or full GPU, or any other situation you met that you want to note down.
### <command_2_name>
Follows above
### <command_3_name>
...

## Table/other form of output
As instructed above

## Summary
Include what's mentioned in the summary session

```