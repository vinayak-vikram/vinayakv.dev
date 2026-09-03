---
title: "Writing an OS powered by a Neural Network"
date: "September 3, 2026"
description: "Writing an async OS that uses a Neural Network as the shell to dispatch syscalls to the kernel. Uses ext4plus for filesystem handling and runs on an arm virt board."
keywords: ["async", "OS", "async OS", "NN", "neural network", "asm", "assembly", "rust", "kernel", "syscall", "ext4", "ext4plus", "osdev", "shell"]
---

<github>vinayak-vikram/nnos</github>

I am an idiot. This should serve as an adequate disclaimer to the nonsense that is about to follow in this blog post.

Anyways, this all started when my good friend and role model [Ashwin](https://ashwinnaren.com) decided to make me one of the most thoughtful birthday gifts I've received, incorporating [my random garbage](https://vinayakv.dev/posts/adcs_snn) into a threejs renderer to show a beautiful [CubeSat detumble simulation](https://08f66aad.yappybday26.pages.dev/). With his birthday coming up, I knew I couldn't exactly slack on doing something.

...and that's where I had one of the worst ideas I have ever had. What if I wrote an OS that used a NN for everyhting above the kernel level? And, to continue the trend of yoinking each others' stuff ig, make it async so I could incorporate Ashwin's excellent [ext4 driver](https://github.com/arihant2math/ext4plus)?

With the last time I did osdev being in 2023, my knowledge of asm completely wiped from my mind, and determination to not use AI during the development of my kernel at all, I'm sure nothing could possibly go wrong.

## Architecture

The architecture I've come up with itself is almost trivially simple. Basically, the NN takes in natural language at the console (probably tokenize and feed?), spits out a syscall intent which the kernel takes in and acts on, and maybe the kernel does some file I/O stuff depending on the syscall.

After this, I had my next idea; what if each syscall could only be executed if the NN's confidence was above some threshold? e.g. 50% to read a file, 98% to delete a file, 50% to print to console, etc... with this, I specced out a basic list of syscalls:

```rust
enum Syscall {
    Print { message: String },
    Read { path: String },
    Write { path: String, data: Vec<u8> },
    Create { path: String },
    Delete { path: String },
    List { path: String },
    Time,
    Reboot,
}
```
Also, for destructive syscalls maybe its best to have the kernel itself prompt the user or something.

# Kernel

Before I could get into the juicy parts (e.g. scheduler, NN, etc...), I had to get my kernel booting. I first tried various Cortex-M targets, as that's the CPU I'm most comfortable with, but being in India with no hardware I had to rely on QEMU where every single Cortex-M target had some defect or another... eventually, I simply settled on the `virt` arm board, which is designed for systems like this.

Writing the bootloader wasn't too bad, and after finishing that I was extremely hopeful that I wouldn't have to touch assembly again, but it was not to be... the first thing I set up was the driver for a bidirectional UART serial console, and since I like making my life hard (and hate polling in general, which is ironic given that I proceeded to write an async runtime) I decided I'd do it the challenging way with IRQs and a ring buffer.

Setting up the interrupt vector table was... a bit of a pain, however. Again, I really miss my trusty Cortex-M and its NVIC. At any rate, the two things I had to do were:
1. Load the exception vector table and bind it. The exception vector table simply tells the processor where in memory the interrupt handlers are.
2. Write an interrupt handler that dispatched to the relevant IRQs

Throughout this, I basically followed this excellent guide on [aarch64 interrupt handling](https://krinkinmu.github.io/2021/01/10/aarch64-interrupt-handling.html) word-for-word. I won't go into the details since he explained it much better than I could, but feel free to check out my clumsy handler in `src/exceptions.s` in the github repo.

With all this done, I felt like I had the scaffolding to get to the first really interesting part of this project; the kernel's scheduler. I've always wanted to do this part of osdev.

## Scheduler & Async runtime

As previously mentioned, `ext4plus` is async. Well, to be exact, it's stated in the README that:

> While this library is async-first, sync APIs are provided via the sync feature. This has known limitations due to features needing to be additive, but it should be sufficient for most use cases.

I really should just go sync here and follow some simple osdev scheduler tutorials. But since I've already committed to pure stupidity, I thought why not go ahead and create a small async runtime myself and build the kernel's scheduler around that[^1]? It's probably prudent to go async anyways, since I'll need to `.await` for the NN[^2]...

[^1]: A few weeks ago, when trying out random Rust nightly features, Ashwin and I messed around a bit with coroutines and `yield`ing. It would be cool to base my runtime/scheduler around this, but I think that's something for another day, given that I'd need to make a significant number of changes to `ext4plus` to get it working with this model. I really love the easy statefulness and control they give you though...

[^2]: A while ago, I forked the MAX78002 NPU's HAL and [added CNN accelerator support](https://github.com/vinayak-vikram/max7800x-hal), switching to that target when I'm back home and `.await`ing on the accelerator's output would be a perfect usecase for this async model. Even disregarding this, the async-await model works very nicely though.

I began by following along with the [Tokio guide](https://tokio.rs/tokio/tutorial/async) to get a simple polling executor working.

### Wakers

Naturally, I needed to get wakers working properly here since nonstop polling is just... stupid. For ergonomics' sake, all my futures were `async fn`s, but the issue with that is that I couldn't do the standard insertion into the raw `poll()` function on the future itself like the example in the Tokio guide. Every writeup I found online was also done with a multithreaded exeuctor in mind, so every single one just used the `ArcWake` thing from the `futures` crate. That meant I had to figure out how the hell the entire [`RawWakerVTable`](https://doc.rust-lang.org/std/task/struct.RawWakerVTable.html) thing worked, but it turned out to be simple; it just wants impls for cloning the waker, dropping the waker, and waking and waking by ref (waking without consuming the waker). So I just wrote a quick implementation for the vtable using `Rc`, with the queue in the async executor now replaced with a queue that stored refs to tasks that were pushed to the queue solely on spawn and by their respective wakers.

Note that the waker context carries through and into `.awaits` because rustorz, so we only really need to define wakers for IRQs, etc. The only real downside of my architecture is that wakers have to be declared as statics.

## Filesystem

With all this done, I could finally incorporate `ext4plus`. The first step for this was loading a ramdisk[^3] and defining the relevant methods over the ramdisk for `ext4plus` to work with. I created a ramdisk simply with `mkfs.ext4` on a blank image (64MB) and passed it in via `-initrd` in QEMU. At boot, using the linux boot convention, QEMU gives us a device tree (pointed to in the `x0` register) which we then use to [locate the ramdisk](https://stackoverflow.com/a/73975329). I then stored a reference to the ramdisk simply as:
```rust
struct Ramdisk {
    ptr: *mut u8,
    len: usize,
}
```
where `ptr` points to the start of the ramdisk's memory segment. Then, all that was left was implementing the [`Ext4Read`](https://docs.rs/ext4plus/latest/ext4plus/trait.Ext4Read.html) and [`Ext4Write`](https://docs.rs/ext4plus/latest/ext4plus/trait.Ext4Write.html) traits on this struct, which was relatively straightforward; all I had to do was use an unsafe `copy_overlapping` to copy slices in whichever direction it wanted. 

[^3]: I considered using a virtio block device for persistent storage but it proved to be wayyy too annoying to implement and anyways, I don't really need persistence as part of this proof-of-concept... I might revisit this in the future though, and might lowkey end up lifting a driver out of [moss](https://github.com/hexagonal-sun/moss-kernel/)[^5].

[^5]: another one of ashwin's projects, yes... the glaze is clearly not ending anytime soon, shush

With these traits provided, it was trivial to provide implementations for all the syscalls I specced earlier, and after doing that it was time for the actually challenging stuff.

# Neural Network

To be completely honest, this was one of the less interesting and more tediouos parts of the project for me. I'm a systems programmer at heart (which I believe I have made abundantly clear in [many many crashouts](https://vinayakv.dev/posts/adcs_snn/#:~:text=Anyways,concerns)...) and this sort of thing is kind of boring for me.

Minor rant aside, I wanted interactions with the shell to be somoething like:
```
> can you tell me what's in foo.txt?
[inf]: inference complete
[inf]: intent: READ("/foo.txt")
[inf]: confidence: 0.688, thresh: 0.60
blah
```
(minus the logs in non-debug versions, idk)

Anyways, I just set up an agentic workflow (e.g. a million and one Qwens) to generate the dataset of such prompts to intents. Basically, each qwen was given an intent definition (such as `"WRITE": "write text into a file, parameters {path} and {text}"`) alongside one natural language and one terse (bash-like) example and told to generate a bunch of natural-language and terse examples of it.

For the model itself I just trained a small (12.5M) transformer that took in a listing of the current working directory as well as the user prompt. I decided to use int8 quantization for performance reasons (QEMU fp acceleration is... garbage...). This entire process was relatively straightforward. At the end of it, I had 68.8% accuracy for exactly spitting out the intents wanted in the validation set, which isn't terrible ig but not the best either. Might work on this in the future, but as previously mentioned I did not feel like investing too much time and effort into this bit of the process.

I then wrote a small loader and runner for the model in Rust (similar in many ways to the [SNN runner](https://vinayakv.dev/posts/adcs_snn) I wrote a while ago...), and the model actually worked! Mostly...

```
> create "birthday.txt"
[nn]: inference
> whats in this directory
[nn]: inference
.
..
lost+found
birthday.txt
> write "happy birthday ashwin!" to birthday.txt
[nn]: inference
```
... and it killed itself.

Given that the model was working fine, I pretty quickly realized something was wrong with the `Write` syscall. I really had absolutely no clue what was going on, so I attached LLDB and pointed Claude at the crash dump, and it turns out that it crashed on atomic writes because the MMU was not initialized (why...??). At any rate, it was trivial to implement a very basic initializer based off of [yet another excellent guide](https://krinkinmu.github.io/2024/01/14/aarch64-virtual-memory.html) from the same guy whose blog post I consulted to set up my interrupt vector table[^4].

[^4]: Side note: I really really want to learn ARM asm in detail and exactly how these chips work instead of copying off blog posts (though that's probably a great first step), its so cool...

Anyways, with that I had a fully working stub of an OS! I'm pretty proud of this project, it's one of my first really serious projects in Rust and a lot of the screwing around I had to do to write my async executor really boosted my understanding of the language. I'll always be a sucker for C, but its nice to start to gain some fluency in another language. It's also great to be able to fully understand Ashwin's yapping about the language as well now :)

Hope you enjoyed reading this post,\
Vinayak
