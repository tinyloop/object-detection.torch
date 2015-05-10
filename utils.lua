--------------------------------------------------------------------------------
-- utility functions for the evaluation part
--------------------------------------------------------------------------------

local function joinTable(input,dim)
  local size = torch.LongStorage()
  local is_ok = false
  for i=1,#input do
    local currentOutput = input[i]
    if currentOutput:numel() > 0 then
      if not is_ok then
        size:resize(currentOutput:dim()):copy(currentOutput:size())
        is_ok = true
      else
        size[dim] = size[dim] + currentOutput:size(dim)
      end    
    end
  end
  local output = input[1].new():resize(size)
  local offset = 1
  for i=1,#input do
    local currentOutput = input[i]
    if currentOutput:numel() > 0 then
      output:narrow(dim, offset,
                    currentOutput:size(dim)):copy(currentOutput)
      offset = offset + currentOutput:size(dim)
    end
  end
  return output
end

--------------------------------------------------------------------------------

local function keep_top_k(boxes,top_k)
  local X = joinTable(boxes,1)
  if X:numel() == 0 then
    return
  end
  local scores = X[{{},-1}]:sort(1,true)
  local thresh = scores[math.min(scores:numel(),top_k)]
  for i=1,#boxes do
    local bbox = boxes[i]
    if bbox:numel() > 0 then
      local idx = torch.range(1,bbox:size(1)):long()
      local keep = bbox[{{},-1}]:ge(thresh)
      idx = idx[keep]
      if idx:numel() > 0 then
        boxes[i] = bbox:index(1,idx)
      else
        boxes[i]:resize()
      end
    end
  end
  return boxes, thresh
end

--------------------------------------------------------------------------------
-- evaluation
--------------------------------------------------------------------------------

local function VOCap(rec,prec)

  local mrec = rec:totable()
  local mpre = prec:totable()
  table.insert(mrec,1,0); table.insert(mrec,1)
  table.insert(mpre,1,0); table.insert(mpre,0)
  for i=#mpre-1,1,-1 do
      mpre[i]=math.max(mpre[i],mpre[i+1])
  end
  
  local ap = 0
  for i=1,#mpre-1 do
    if mrec[i] ~= mrec[i+1] then
      ap = ap + (mrec[i+1]-mrec[i])*mpre[i+1]
    end
  end
  return ap
end

--------------------------------------------------------------------------------

local function boxoverlap(a,b)
  --local b = anno.objects[j]
  local b = b.xmin and {b.xmin,b.ymin,b.xmax,b.ymax} or b
    
  local x1 = a:select(2,1):clone()
  x1[x1:lt(b[1])] = b[1] 
  local y1 = a:select(2,2):clone()
  y1[y1:lt(b[2])] = b[2]
  local x2 = a:select(2,3):clone()
  x2[x2:gt(b[3])] = b[3]
  local y2 = a:select(2,4):clone()
  y2[y2:gt(b[4])] = b[4]
  
  local w = x2-x1+1;
  local h = y2-y1+1;
  local inter = torch.cmul(w,h):float()
  local aarea = torch.cmul((a:select(2,3)-a:select(2,1)+1) ,
                           (a:select(2,4)-a:select(2,2)+1)):float()
  local barea = (b[3]-b[1]+1) * (b[4]-b[2]+1);
  
  -- intersection over union overlap
  local o = torch.cdiv(inter , (aarea+barea-inter))
  -- set invalid entries to 0 overlap
  o[w:lt(0)] = 0
  o[h:lt(0)] = 0
  
  return o
end

--------------------------------------------------------------------------------

local function VOCevaldet(dataset,scored_boxes,cls)
  local num_pr = 0
  local energy = {}
  local correct = {}
  
  local count = 0
  
  for i=1,dataset:size() do   
    local ann = dataset:getAnnotation(i)   
    local bbox = {}
    local det = {}
    for idx,obj in ipairs(ann.object) do
      if obj.name == cls and obj.difficult == '0' then
        table.insert(bbox,{obj.bndbox.xmin,obj.bndbox.ymin,
                           obj.bndbox.xmax,obj.bndbox.ymax})
        table.insert(det,0)
        count = count + 1
      end
    end
    
    bbox = torch.Tensor(bbox)
    det = torch.Tensor(det)
    
    local num = scored_boxes[i]:numel()>0 and scored_boxes[i]:size(1) or 0
    for j=1,num do
      local bbox_pred = scored_boxes[i][j]
      num_pr = num_pr + 1
      table.insert(energy,bbox_pred[5])
      
      if bbox:numel()>0 then
        local o = boxoverlap(bbox,bbox_pred[{{1,4}}])
        local maxo,index = o:max(1)
        maxo = maxo[1]
        index = index[1]
        if maxo >=0.5 and det[index] == 0 then
          correct[num_pr] = 1
          det[index] = 1
        else
          correct[num_pr] = 0
        end
      else
          correct[num_pr] = 0        
      end
    end
    
  end
  
  if #energy == 0 then
    return 0,torch.Tensor(),torch.Tensor()
  end
  
  energy = torch.Tensor(energy)
  correct = torch.Tensor(correct)
  
  local threshold,index = energy:sort(true)

  correct = correct:index(1,index)

  local n = threshold:numel()
  
  local recall = torch.zeros(n)
  local precision = torch.zeros(n)

  local num_correct = 0

  for i = 1,n do
      --compute precision
      num_positive = i
      num_correct = num_correct + correct[i]
      if num_positive ~= 0 then
          precision[i] = num_correct / num_positive;
      else
          precision[i] = 0;
      end
      
      --compute recall
      recall[i] = num_correct / count
  end

  ap = VOCap(recall, precision)
  io.write(('AP = %.4f\n'):format(ap));

  return ap, recall, precision
end


--------------------------------------------------------------------------------
-- data preparation
--------------------------------------------------------------------------------

local function rgb2bgr(I)
  local out = I.new():resizeAs(I)
  for i=1,I:size(1) do
    out[i] = I[I:size(1)+1-i]
  end
  return out
end

local function prepareImage(I,typ)
  local typ = typ or 1
  local mean_pix = typ == 1 and {128.,128.,128.} or {103.939, 116.779, 123.68}
  local I = I
  if I:dim() == 2 then
    I = I:view(1,I:size(1),I:size(2))
  end
  if I:size(1) == 1 then
    I = I:expand(3,I:size(2),I:size(3))
  end
  I = rgb2bgr(I):mul(255)
  for i=1,3 do
    I[i]:add(-mean_pix[i])
  end
  return I
end



--------------------------------------------------------------------------------
-- packaging
--------------------------------------------------------------------------------

local utils = {}

utils.keep_top_k = keep_top_k
utils.VOCevaldet = VOCevaldet
utils.VOCap = VOCap
utils.prepareImage = prepareImage

return utils


