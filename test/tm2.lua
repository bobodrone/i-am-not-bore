-- Host-side test, run with plain `lua`. See the guard note in run_script.lua.
if rawget(_G, "_path") ~= nil then
  print("i-am-not-bore: test/ is a host-side harness, not a norns script")
  return
end

math.randomseed(4242)
local function mutate(v,k)
  local c = math.max(0,(0.5-k)*2)
  if math.random()<c then return 1-v else return math.random() end
end
local function laps(k,len,n,density)
  density = density or 0.5
  local reg={} for i=1,16 do reg[i]=math.random() end
  local pos,out=0,{}
  for l=1,n do
    local b={}
    for _=1,len do
      pos=(pos%len)+1
      local v=reg[pos]
      b[#b+1]=(v<density) and "1" or "0"
      if math.random()<(1-k) then reg[pos]=mutate(v,k) end
    end
    out[l]=table.concat(b)
  end
  return out
end
local fails=0
local function check(n,c,d) print(string.format("%-50s %s  %s",n,c and "PASS" or "FAIL",d or "")); if not c then fails=fails+1 end end

print("=== fully CW (k=1): locked loop ===")
local s=laps(1.0,8,6); check("repeats exactly every lap", s[1]==s[3] and s[3]==s[6], s[1].." x6")

print("\n=== fully CCW (k=0): locked inverse loop, 2x length ===")
s=laps(0.0,8,6)
check("lap N == lap N+2", s[1]==s[3] and s[3]==s[5] and s[2]==s[4], s[1].." / "..s[2])
check("lap N+1 is the inverse of lap N", (function()
  for i=1,8 do if s[1]:sub(i,i)==s[2]:sub(i,i) then return false end end return true end)(),
  s[1].." <-> "..s[2])

print("\n=== centre (k=0.5): keeps changing ===")
s=laps(0.5,16,8)
local same=0; for i=2,#s do if s[i]==s[1] then same=same+1 end end
check("laps all differ", same==0, s[1].." -> "..s[2])

print("\n=== no cliff at the centre detent ===")
local function drift(k,len,n,trials)
  local tot,cnt=0,0
  for _=1,trials do
    local L=laps(k,len,n)
    for i=2,#L do local d=0
      for j=1,len do if L[i]:sub(j,j)~=L[i-1]:sub(j,j) then d=d+1 end end
      tot=tot+d; cnt=cnt+len end
  end
  return tot/cnt
end
print("  knob   bits changed per step")
local vals={}
for _,k in ipairs({0.0,0.1,0.2,0.3,0.4,0.45,0.5,0.55,0.6,0.7,0.8,0.9,1.0}) do
  local d=drift(k,16,20,30); vals[#vals+1]={k,d}
  print(string.format("  %.2f   %.3f",k,d))
end
-- the cliff test: neighbours either side of centre must be close
local a,b
for _,v in ipairs(vals) do if math.abs(v[1]-0.45)<1e-9 then a=v[2] end
                           if math.abs(v[1]-0.55)<1e-9 then b=v[2] end end
check("0.45 vs 0.55 differ by < 0.1 bits/step", math.abs(a-b)<0.1,
  string.format("%.3f vs %.3f", a, b))
-- monotonic from centre to CW
local ok,prev=true,nil
for _,v in ipairs(vals) do if v[1]>=0.5 then
  if prev and v[2]>prev+0.02 then ok=false end prev=v[2] end end
check("monotonically locks from centre to CW", ok)

print("\n=== density still non-destructive ===")
s=laps(1.0,8,4,0.2); local t=laps(1.0,8,4,0.8)
check("density only changes how many fire", #s[1]==8 and #t[1]==8,
  "d=0.2 "..s[1].."   d=0.8 "..t[1])
print(fails==0 and "\nALL CHECKS PASSED" or "\n"..fails.." FAILURE(S)")
os.exit(fails==0 and 0 or 1)
