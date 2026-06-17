---
title: "Writing & Training a Science Bowl Set Generator"
date: "April 9, 2026"
description: "Writing a simple CLI to generate science bowl packets from textbooks."
---

<github>vinayak-vikram/bowler</github>
<github>vinayak-vikram/scibowlsetsannotated</github>

I began by writing a simple [rust program](https://github.com/vinayak-vikram/bowler/blob/a64d5b6d46c674c776747a03f67eefda5af34e39/src/main.rs) to give me the text contents of a PDF, to speed things up. Then, I [used it](https://github.com/vinayak-vikram/scibowlsetsannotated/blob/main/extract.sh) to export a bunch of sets to `.txt`s (see the `scibowlsetsannotated` repo).

My first thought was to have a simple pipeline where an LLM generated around 3 questions per page, which was passed into a filtering and classification algorithm/model and finally back into an LLM for option generation (in the event that it is MCQ). However, I realized that if pages were overly dense/overly sparse, this could go horribly. My current idea is something like:

- use LLM to parse textbook and chunk subjects
- store in FAISS database or something similar for nearby-vector search
- select level from vector graph to use for overarching topics + randomly select subnodes? or use LLM to generate a plan for the packet from the vector graph
- use LLM to generate targeted questions, again from vector graph sublevels
- verification by LLM? bro why do i have so many LLMs omfg
- MCQ generation by looking at nearest embeddings for distractors?
