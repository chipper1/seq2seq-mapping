--[[

-- adapted from encoder-decoder-coupling example from Element-research/rnn/example and char-rnn by Karpathy

-- This example includes -
    -- multiple LSTM layered encoder-decoder
    -- dropout between stacked LSTM layers
    -- input sequences can be of any length
        -- I'm not aware of effects of arbitrary length sequences during training for real world tasks
        -- inside a batch, all the sequences should be of the same length or you'll get an exception
        -- to form batch from variable length sequence use padding.
            -- recommended padding style is: {0,0,0,GO,1,2,3,4} for encoder and {1,2,3,4,EOS,0,0,0} for the decoder.(0 is used for padding.)
	-- validation, early-stopping
	-- using RMSProp, can easily change to another optimization procedure supported by optim package eg. adam/adagrad for training
	-- saving model at predefined checkpoints and resuming training from saved model
	-- running on nvidia GPU
	-- sampling from saved model
	-- two Synthetic data sets

-- NOTE on using a saved model
    -- If you run your experiment on GPU then before using the saved model, convert it to a cpu model first using convert_gpuCheckpoint_to_cpu.lua
--	
]]--

require 'torch'
require 'rnn'
require 'dpnn'
require 'optim'

-- use command line options for model and training configuration
-- I may not be using some of these options in this example

cmd = torch.CmdLine()
cmd:text()
cmd:text('Train a character-level encoder-decoder sequence model')
cmd:text()
cmd:text('Options')
-- data
cmd:option('-synthetic', 2, 'pass 1 to use synthetic data for task1: ab -> aabb, 2 for task2: ab -> abc')
-- model params
cmd:option('-hiddenSize', 128, 'size of LSTM internal state')
cmd:option('-num_layers', 2, 'number of layers in the LSTM')
-- optimization
cmd:option('-learningRate',0.01,'learning rate')
cmd:option('-learning_rate_decay',0.97,'learning rate decay')
cmd:option('-learning_rate_decay_after',10,'in number of epochs, when to start decaying the learning rate')
cmd:option('-decay_rate',0.95,'decay rate for rmsprop')
cmd:option('-dropout',0.5,'dropout for regularization, used after each RNN hidden layer. 0 = no dropout')

cmd:option('-batch_size',20,'number of sequences to train on in parallel')
cmd:option('-max_epochs',10,'number of full passes through the training data')
cmd:option('-grad_clip',5,'clip gradients at this value, pass 0 to disable')
cmd:option('-train_frac',0.90,'fraction of data that goes into train set')
cmd:option('-val_frac',0.10,'fraction of data that goes into validation set')
            -- test_frac will be computed as (1 - train_frac - val_frac)
cmd:option('-init_from', '', 'initialize network parameters from checkpoint at this path')
-- bookkeeping
cmd:option('-seed',16,'torch manual random number generator seed')
cmd:option('-print_every',10,'how many steps/minibatches between printing out the loss')
cmd:option('-eval_val_every',500,'every how many iterations should we evaluate on validation data?')
cmd:option('-checkpoint_dir', 'checkpoints', 'output directory where checkpoints get written')
cmd:option('-savefile','model_','filename to autosave the checkpont to. Will be inside checkpoint_dir/')
cmd:option('-accurate_gpu_timing',0,'set this flag to 1 to get precise timings when using GPU. Might make code bit slower but reports accurate timings.')
-- GPU/CPU
cmd:option('-gpuid',0,'which gpu to use. -1 = use CPU')
cmd:text()

-- parse input params
opt = cmd:parse(arg)
torch.manualSeed(opt.seed)
if opt.train_frac + opt.val_frac > 1 then
    print(' sum of train_frac and val_frac exceeds  1, exiting.')
    os.exit()
end 
local split_fractions = {opt.train_frac, opt.val_frac, 1 - (opt.train_frac + opt.val_frac)} 

-- initialize cunn/cutorch for training on the GPU and fall back to CPU gracefully
if opt.gpuid >= 0 then
    local ok, cunn = pcall(require, 'cunn')
    local ok2, cutorch = pcall(require, 'cutorch')
    if not ok then print('package cunn not found!') end
    if not ok2 then print('package cutorch not found!') end
    if ok and ok2 then
        print('using CUDA on GPU ' .. opt.gpuid .. '...')
        cutorch.setDevice(opt.gpuid + 1) -- note +1 to make it 0 indexed! sigh lua
        cutorch.manualSeed(opt.seed)
    else
        print('If cutorch and cunn are installed, your CUDA toolkit may be improperly configured.')
        print('Check your CUDA toolkit installation, rebuild cutorch and cunn, and try again.')
        print('Falling back on CPU mode')
        opt.gpuid = -1 -- overwrite user setting
    end
end

-- load data
local loader
if opt.synthetic > 0 then
    print ('Using synthetic data ...')
    local Synthetic = require 'SyntheticData'
    loader = Synthetic.create(opt.synthetic, 9000, opt.batch_size, unpack(split_fractions))
-- else
--    or load your own data here
end    
    
-- make sure output directory exists
if not path.exists(opt.checkpoint_dir) then lfs.mkdir(opt.checkpoint_dir) end

opt.vocabSize = loader.vocab_size
print('vocab size:', loader.vocab_size)

-- Build the model

-- helper functions to for encoder-decoder coupling.
--[[ Forward coupling: Copy encoder cell and output to decoder LSTM ]]--
local function forwardConnect(encLSTMs, decLSTMs)
    seqLen = #(encLSTMs[1].outputs)
    for i = 1, #encLSTMs do
        local encLSTM, decLSTM = encLSTMs[i], decLSTMs[i]
        decLSTM.userPrevOutput = nn.rnn.recursiveCopy(decLSTM.userPrevOutput, encLSTM.outputs[seqLen])
        decLSTM.userPrevCell = nn.rnn.recursiveCopy(decLSTM.userPrevCell, encLSTM.cells[seqLen])
    end
end

--[[ Backward coupling: Copy decoder gradients to encoder LSTM ]]--
local function backwardConnect(encLSTMs, decLSTMs)
    for i = 1, #encLSTMs do
        local encLSTM, decLSTM = encLSTMs[i], decLSTMs[i]
        encLSTM.userNextGradCell = nn.rnn.recursiveCopy(encLSTM.userNextGradCell, decLSTM.userGradPrevCell)
        encLSTM.gradPrevOutput = nn.rnn.recursiveCopy(encLSTM.gradPrevOutput, decLSTM.userGradPrevOutput)
    end
end

local enc, dec, criterion
local encLSTMs = {}
local decLSTMs = {}

-- Hack to get all trainable parameters of our model in one flattend tensor (required for optim package)
local allModContainer

-- check if need to load from previous experiment
if opt.init_from ~= '' then
        print('loading model from:', opt.init_from)
        checkpoint = torch.load(opt.init_from)

        enc = checkpoint.enc
        encLSTMs = checkpoint.encLSTMs
        dec = checkpoint.dec
        decLSTMs = checkpoint.decLSTMs
        criterion = checkpoint.criterion
        allModContainer = checkpoint.allModContainer
        opt.learningRate = checkpoint.opt.learningRate
        opt.learning_rate_decay_after = checkpoint.epoch >= opt.learning_rate_decay_after and 0 or opt.learning_rate_decay_after - checkpoint.epoch

else
    allModContainer = nn.Container()

    -- Encoder
    enc = nn.Sequential()
    enc:add(nn.OneHot(opt.vocabSize))       -- requires dpnn module from element-research
    enc:add(nn.SplitTable(1, 2))            -- works for both online and mini-batch mode

    local anLSTM 
    for i = 1, opt.num_layers do
        if i == 1 then anLSTM = nn.LSTM(opt.vocabSize, opt.hiddenSize)
        else
            anLSTM = nn.LSTM(opt.hiddenSize, opt.hiddenSize)
            if opt.dropout > 0 then enc:add(nn.Sequencer(nn.Dropout(opt.dropout))) end
        end
        enc:add(nn.Sequencer(anLSTM))
        allModContainer:add(anLSTM)
        table.insert(encLSTMs, anLSTM)
    end
    enc:add(nn.SelectTable(-1))

    -- Decoder
    dec = nn.Sequential()
    dec:add(nn.OneHot(opt.vocabSize))      -- requires dpnn module from element-research
    dec:add(nn.SplitTable(1, 2))           -- works for both online and mini-batch mode

    for i = 1, opt.num_layers do
        if i == 1 then anLSTM = nn.LSTM(opt.vocabSize, opt.hiddenSize); decLSTM = anLSTM        -- the first LSTM in decoder LSTM stack
        else
            anLSTM = nn.LSTM(opt.hiddenSize, opt.hiddenSize)
            if opt.dropout > 0 then dec:add(nn.Sequencer(nn.Dropout(opt.dropout))) end
        end
        allModContainer:add(anLSTM)
        dec:add(nn.Sequencer(anLSTM))
        table.insert(decLSTMs, anLSTM)
    end
    
    dec:add(nn.Sequencer(nn.Linear(opt.hiddenSize, opt.vocabSize)))
    allModContainer:add(linear)
    dec:add(nn.Sequencer(nn.LogSoftMax()))

    criterion = nn.SequencerCriterion(nn.ClassNLLCriterion())
end

--print ('encoder', enc)
--print ('decoder', dec)

-- run on gpu if possible
if opt.gpuid >=0 then
	enc:cuda()
	dec:cuda()
	criterion:cuda()
end

-- capture all parameters in a single 1-D array, there is no other use for allModContainer
params, grad_params = allModContainer:getParameters()

local splitter = opt.gpuid >= 0 and nn.SplitTable(1,1):cuda() or nn.SplitTable(1, 1)

-- cross validation & testing
-- split_index: pass 2 for validate and 3 for test
function evalLoss(split_index)
    --print('calculating validation loss...')
    n = split_index==2 and nval or ntest

    -- set evaluation mode
    enc:evaluate()
    dec:evaluate()

    sumError = 0
    for idx = 1,n do        
        local encInSeq, decInSeq, decOutSeq = loader:next_batch(split_index)
        if opt.gpuid >= 0 then
                encInSeq = encInSeq:float():cuda()
                decInSeq = decInSeq:float():cuda()
                decOutSeq = decOutSeq:float():cuda()
        end
        decOutSeq =  splitter:forward(decOutSeq)

        -- forward
        local encOut = enc:forward(encInSeq)
        forwardConnect(encLSTMs, decLSTMs)
        local decOut = dec:forward(decInSeq)
        local err = criterion:forward(decOut, decOutSeq)

        sumError = sumError + err
    end

    -- set training mode
    enc:training()
    dec:training()

	-- return avg validation loss
    return sumError/n
end

-- function for training with optim package
function feval(x)
    if x ~= params then
        params:copy(x)
    end

--  reset gradients
    grad_params:zero()

    local encInSeq, decInSeq, decOutSeq = loader:next_batch(1)          -- argument 1 in next_batch(1) indicates training batch
    if opt.gpuid >= 0 then 
        encInSeq = encInSeq:float():cuda()
        decInSeq = decInSeq:float():cuda()
        decOutSeq = decOutSeq:float():cuda()
    end
    decOutSeq =  splitter:forward(decOutSeq) 

--  forward pass
    local encOut = enc:forward(encInSeq)
    forwardConnect(encLSTMs, decLSTMs)
    local decOut = dec:forward(decInSeq)
    local train_loss = criterion:forward(decOut, decOutSeq)

--  backward pass
    local gradOutput = criterion:backward(decOut, decOutSeq)
    dec:backward(decInSeq, gradOutput)
    backwardConnect(encLSTMs, decLSTMs)
    local zeroTensor = opt.gpuid >= 0 and torch.CudaTensor(encOut):zero() or torch.Tensor(encOut):zero()
    enc:backward(encInSeq, zeroTensor)

    -- parameters update will be handled automatically by optim procedure.
    --dec:updateParameters(opt.learningRate)
    --enc:updateParameters(opt.checkpoint.opt)

    -- clip gradient element-wise (not default)
    if opt.grad_clip > 0 then grad_params:clamp(-opt.grad_clip, opt.grad_clip) end

    return train_loss, grad_params
end

-- get training data    TODO: do batching for real data as well.
ntrain, nval, ntest = unpack( loader.batch_split_sizes )
local iterations = opt.max_epochs * ntrain

-- store stuff
local train_losses = {}
local val_losses = {}

-- time experiment
local expTimer = torch.Timer()

-- training with optim package
--[[ ]]--
local optim_state = {learningRate = opt.learningRate, alpha = opt.decay_rate}
for i = 1, iterations do
    local epoch = i / loader.ntrain
    local timer = torch.Timer()
    local _, loss = optim.rmsprop(feval, params, optim_state)
    if opt.accurate_gpu_timing == 1 and opt.gpuid >= 0 then

--      Note on timing: The reported time can be off because the GPU is invoked async. If one
--      wants to have exactly accurate timings one must call cutorch.synchronize() right here.
--      I will avoid doing so by default because this can incur computational overhead.

        cutorch.synchronize()
    end
    local time = timer:time().real
    
    local train_loss = loss[1] -- the loss is inside a list, pop it
    train_losses[i] = train_loss

    -- exponential learning rate decay
    if i % loader.ntrain == 0 and opt.learning_rate_decay < 1 then
        if epoch >= opt.learning_rate_decay_after then
            local decay_factor = opt.learning_rate_decay
            optim_state.learningRate = optim_state.learningRate * decay_factor -- decay it
            print('decayed learning rate by a factor ' .. decay_factor .. ' to ' .. optim_state.learningRate)
        end
    end


    if i % opt.print_every == 0 then
        print(string.format("%d/%d (epoch %.3f), train_loss = %6.8f, grad/param norm = %6.4e, time/batch = %.4fs", i, iterations, epoch, train_loss, grad_params:norm() / params:norm(), time))
    end

    -- every now and then or on last iteration
    if i % opt.eval_val_every == 0 or i == iterations then
        -- evaluate loss on validation data
        val_loss = evalLoss(2, enc, encLSTM, dec, decLSTM, criterion)       -- 2 = validation
        val_losses[i] = val_loss

		-- handle early stopping if things are going really bad
        last_loss = last_loss or val_loss
        if val_loss > last_loss * 3 then
            print('loss is exploding, aborting.')
            break -- halt
        end

        local savefile = string.format('%s/%s_epoch%.2f_val_loss%.4f.t7', opt.checkpoint_dir, opt.savefile, epoch, val_loss)            
        --print('saving checkpoint to ' .. savefile)
        print(string.format("cross-val_loss = %6.8f",val_loss))
        local checkpoint = {}
        checkpoint.opt = opt
        checkpoint.opt.learningRate = optim_state.learningRate
        checkpoint.enc = enc
        checkpoint.encLSTMs = encLSTMs
        checkpoint.dec = dec
        checkpoint.decLSTMs = decLSTMs
        checkpoint.criterion = criterion
        checkpoint.allModContainer = allModContainer
        checkpoint.i = i
        checkpoint.val_losses = val_losses
        checkpoint.train_losses = train_losses
        checkpoint.test_losses = test_losses
        checkpoint.epoch = epoch
        checkpoint.vocab = loader.vocab_mapping
        torch.save(savefile, checkpoint)
    end
   
    if i % 100 == 0 then collectgarbage() end

    -- check for errors
    if train_loss ~= train_loss then
        print('loss is NaN.  This usually indicates a bug.')
        break -- halt
    end
end
--[[ ]]--


--[[
-- simple SGD training (without optim package, if you want to see how is that done)
for i = 1, iterations do
    local epoch = i / loader.ntrain
    local timer = torch.Timer()

    -- get next batch  
    local encInSeq, decInSeq, decOutSeq = loader:next_batch( 1)          -- argument 1 in next_batch(1) indicates training batch
	if opt.gpuid >= 0 then 
		encInSeq = encInSeq:float():cuda()
		decInSeq = decInSeq:float():cuda()
		decOutSeq = decOutSeq:float():cuda()
	end
  	decOutSeq =  splitter:forward(decOutSeq) 

    -- reset gradients
    enc:zeroGradParameters()
    dec:zeroGradParameters()

    -- Forward pass
    local encOut = enc:forward(encInSeq)
    forwardConnect(encLSTM, decLSTM)
    local decOut = dec:forward(decInSeq)
    local train_loss = criterion:forward(decOut, decOutSeq)
   
    train_losses[i] = train_loss
    print(string.format("Epoch %d ; Batch %d; NLL train_loss = %f ", epoch, i, train_loss))

   -- Backward pass
    local gradOutput = criterion:backward(decOut, decOutSeq)
    dec:backward(decInSeq, gradOutput)
    backwardConnect(encLSTM, decLSTM)
    local zeroTensor = opt.gpuid >= 0 and torch.CudaTensor(encOut):zero() or torch.Tensor(encOut):zero()
    enc:backward(encInSeq, zeroTensor)


    -- update parameters
    dec:updateParameters(opt.learningRate)
    enc:updateParameters(opt.learningRate)    

	--	...
end
]]--


local time = expTimer:time().real
print ('experiment took', time, 'sec..')
