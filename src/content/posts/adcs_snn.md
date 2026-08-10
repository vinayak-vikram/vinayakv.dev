---
title: "SNN-based ADCS implementation"
date: "August 9, 2026"
description: "Using a Spiking Neural Network to process multimodal sensor inputs to output a dipole to control a CubeSat via magnetorquers"
---

<github>vinayak-vikram/adcs_snn</github>

At an orchestra camp last week, when talking to a friend from Los Gatos High School, I came to hear about their [CubeSat project](https://lgcubesat.com). They had quite a few ideas, but the one I was most intrigued by was their idea of using a Spiking Neural Netowrk for the software part of their ADCS. With a long flight coming up (no internet for about 10 hours), I figured I'd try to implement a SNN that takes in magnetometer and gyro readings and outputs a magnetorquer dipole purely for lols, building off of my understanding and implementation of ADCS from [PixelSat I](https://projectpixelorbital.com/software-2).

## Preliminaries

I decided early on that I would first try to have the network emulate the behavior of the B-dot method (due to time constraints). The B-dot method simply spits out a magnetic dipole $\mathbf{m}$ to hand to the magnetorquers via

$$
\mathbf{m} = k\,(\boldsymbol{\omega} \times \mathbf{B})
$$

where $\boldsymbol{\omega}$ is body angular velocity and $\mathbf{B}$ is the local field in the body frame.
The fact that this chiefly uses continuous rates makes it quite interesting for the SNN application.

To set up training, I literally just copied over the sim pipeline I wrote for PixelSat a while ago and got it to export to csv like so, were $\mathbf{m}$ was the biblically accurate B-dot dipole:
```csv
w1,w2,w3,B1,B2,B3,m1,m2,m3
-0.05066173506673986,0.013779941498795764,0.053387149809225785,1.086753062025618e-05,-1.939359386601369e-06,2.1633989080157035e-05,0.02008259870082829,0.0838100954247812,-0.0025751312370154056
-0.049576843516165627,0.013502470275657161,0.052817296116457864,6.6960691167617295e-06,-1.111784952403111e-05,2.0571268571910903e-05,0.04324888464568793,0.06867634141374578,0.023038720593817286
...
-0.034273344526176884,0.008147496714583124,0.03633959716856362,-2.2553554805807198e-05,2.60379969906276e-06,1.5741299178307867e-05,0.0016815575583482745,-0.014004006316719254,0.004725704475967546
```

In total I got around $200,000$ rows of training data, more than adequate for the purposes of this thing, ranging from stabilization with $\mathbf{\omega} \approx \mathbf{0}$ to the torques required to rectify wild tumbles.

As for a SNN library as well as documentation, I just chekced out a shallow clone of the snnTorch repo; the examples in that repo as well as their `leaky` neuron implementation proved to be incredibly helpful in the future. Note to future self: a good LSP saves a lot of time...

## Spiking neural networks

It is probably prudent to give a quick summary of what a SNN is.

A regular neural network layer has no memory between runs. A SNN, however, is comprised of many LIF (Leaky Integrate-and-Fire) neurons, which are basically a simplified model of an actual nerve cell. They accumulate incoming electrical signals, let voltage leak away over time, and fire a discrete spike when their internal voltage crosses some set threshold. Note that this makes them great models for rate-based control laws...

We can express that entire thing mathematically as:

$$
V_t = \beta\,V_{t-1} + I_t - S_{t-1}\cdot V_{th}, \qquad S_t = \mathbb{1}[V_t > V_{th}],
$$
where $\beta$ is simply a decay term for the last step's charge, and $S_t$ is the neuron's spike output at time $t$ ($0$ or $1$).

The issue here is that $S$ comes from a step function, so simple backpropagation-based training does not work. snnTorch gets around this with a surrogate gradient, swapping in a smooth stand-in function *only* for the backward pass, so training works normally. This function is then replaced with the neuron's control function in the actual net so that forward-propagation operates exactly as a SNN should.

## Input data

The last thing I needed to do before starting work is figure out how to feed data into the model.
I originally thought of going about this by spike-encoding the raw sensor input. The main issue here is that this would require either another model or handcrafted heuristics, neither of which i was particularly happy with.

Turns out that what makes a network a SNN is that the *hidden* layers are LIF neurons. Therefore, the input layer can actually just be a standard input layer. [snnTorch's own regression tutorial](https://github.com/jeshraghian/snntorch/blob/master/examples/tutorial_regression_1.ipynb) actually does exactly this: raw scalar input goes through a `Linear` layer to become a current, that current drives the first `Leaky` layer, and the readout is the last layer's continuous membrane potential rather than a spike count. I basically did the same thing, with 6 inputs (angular velocity, local magnetic field) and 3 readouts (commanded dipole).

## Training the model

With the data I'd gotten from my training pipline, I trained a basic model. The loss looked fine (average $3.7\times 10^{-4}$, final loss $4.5\times 10^{-5}$), but the model was simply not detumbling the satellite. This was because every prediction coming out of the model was identical regardless of input:

```
dipole:  [-0.00072, -0.00259, 0.00023]
dipole:  [-0.00072, -0.00259, 0.00023]
dipole:  [-0.00072, -0.00259, 0.00023]
...
```

Turns out that predicting all zeroes on the dataset gives MSE $3.4\times 10^{-4}$. So, the model had literally just learned the sample mean. Excellent.

So then I thought it might be fixed by adding per-quantity RMS scaling (dividing each quantity by its root-mean-square). Same architecture otherwise. After training, it detumbled the satellite pretty darn well. The network was also actually spiking (around 6.4%), which was excellent.

## My Rust implementation

Small tangent. Feel free to skip. Anyways, why the hell has the entire ML community decided that *python* should be the language that we all use? Beginner friendliness? I personally believe that if you are incompetent enough at programming that you can't use any real systems language, ML should not be one of your pressing concerns.

Getting to the point, I didn't want inference through a Python/PyTorch stack, and especially not for something that is a proof-of-concept for flight software. Training in snnTorch is fine, there was no real reason to hand-roll backprop and everything. But I wanted the thing that actually runs the network to be small and dependency-free. Ended up writing the inference layer in Rust because the sim already used Zenoh and I was too lazy to get Zenoh working with C, but really, anything works.

I wrote a quick python script to drop the `model.pt` file in a bin file with all the weights, biases, per-neuron betas, thresholds, etc.... Then, I formalized the per-neuron update step from a paper I'd downloaded and verified it against the snnTorch source to make sure I wasn't doing anything stupid:

$$
\text{reset} = \mathbb{1}[V_{t-1} > V_{th}], \qquad
V_t = \beta\,V_{t-1} + I_t - \text{reset}\cdot V_{th}, \qquad
S_t = \mathbb{1}[V_t > V_{th}]
$$

Implementing the SNN was relatively simple. I simply held a flat `Vec<f32>` for each layer's weights, biases, and per-neuron betas. Each predict step simply takes the raw input, normalizes it, and computes the input layer's current once up front ($\mathbf{I}=W\mathbf{x}+\mathbf{b}$, where $\mathbf{b}$ is the bias vector), then runs the actual timestep loop. Each loop, both LIF layers (hidden, output) just update `reset = if mem > threshold { threshold } else { 0.0 }`, then `mem = beta * mem + current - reset`, then check `mem > threshold` again to get the spike that feeds the next layer. The output layer runs the same update but skips the reset, and we read the membrane potentials after the last timestep and scale to get the dipole.

Once I verified it with the sim, I made it properly event-driven instead of branching over all 256 hidden neurons every timestep regardless of whether they fired:

```rust
for o in 0..h {
    let row = o * h;
    let mut acc = 0.0f32;
    for &i in &fired_in {
        acc += self.w_hidden[row + i];
    }
    // ...
}
```

This took 10k inferences from 8.44s to 2.50s. The main takeaway from this is that the LGHS kids might be on to something; the sparsity the SNN gives you for free is actually worth something here and even my yoloed crap from the plane runs fast enough that it might actually be feasible in flight software.

## Conclusions

Running it live against the sim in its trained range tracks the analytic law reasonably well, generally within 10-25% on each axis, and omega does trend down over time.

A small issue occurs when we are not tumbling at all, though; the SNN commands a small but nonzero dipole, which spins the satellite up from a dead stop rather than leaving it alone (it rectifies itself pretty quickly, so it never tumbles out of control, but mehhh). My best guess at the cause is the RMS normalization from the training fix; since the input spans a couple orders of magnitude, near-zero samples end up contributing almost nothing to the MSE loss, so the network never really learned that small input should mean small output. I haven't fixed it yet and most likely never will; again, this was just a random project I did because I had time to kill.

The other thing that really interests me would be trying out the other b-dot definition ($\mathbf{m}=-\text{d}\mathbf{B}/\text{d}t$) since I feel like the rate-based defintiion of that really suits a SNN.

I still have not figured out how to organically end a blog post, but thanks for reading, and I hope you had some interesting ideas of your own from this!
