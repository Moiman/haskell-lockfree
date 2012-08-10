{-# LANGUAGE BangPatterns, CPP #-}
-- TypeFamilies, FlexibleInstances

-- | Michael and Scott lock-free, single-ended queues.
-- 
-- This is a straightforward implementation of classic Michael & Scott Queues.
-- Pseudocode for this algorithm can be found here:
-- 
--   <http://www.cs.rochester.edu/research/synchronization/pseudocode/queues.html>

module Data.Concurrent.Queue.MichaelScott
 (
   -- The convention here is to directly provide the concrete
   -- operations as well as providing the typeclass instances.
   LinkedQueue(), newQ, nullQ, pushL, tryPopR, 
 )
  where

import Control.Monad
import Data.IORef
import System.Mem.StableName
import Text.Printf
import GHC.IO (unsafePerformIO)
import GHC.Conc
import Control.Concurrent.MVar

import qualified Data.Concurrent.Deque.Class as C

import Data.CAS (casIORef, ptrEq)
-- NOTE: you can switch which CAS implementation is used here:
-- import Data.CAS.Internal.Fake (casIORef, ptrEq)
-- #warning "Using fake CAS"
-- import Data.CAS.Internal.Native (casIORef, ptrEq)
-- #warning "Using NATIVE CAS"


-- Considering using the Queue class definition:
-- import Data.MQueue.Class

data LinkedQueue a = LQ 
    { head :: IORef (Pair a)
    , tail :: IORef (Pair a)
    }

data Pair a = Null | Cons a (IORef (Pair a))


-- | Push a new element onto the queue.  Because the queue can grow,
--   this always succeeds.
pushL :: LinkedQueue a -> a  -> IO ()
pushL (LQ headPtr tailPtr) val = do
   r <- newIORef Null
   let newp = Cons val r   -- Create the new cell that stores val.
   tail <- loop newp
   -- After the loop, enqueue is done.  Try to swing the tail.
   -- If we fail, that is ok.  Whoever came in after us deserves it.
   casIORef tailPtr tail newp
   return ()
 where 
  loop newp = do 
   tail <- readIORef tailPtr -- [Re]read the tailptr from the queue structure.
   case tail of
     -- The head and tail pointers should never themselves be NULL:
     Null -> error "push: LinkedQueue invariants broken.  Internal error."
     Cons _ nextPtr -> do
	next <- readIORef nextPtr

-- Optimization: The algorithm can reread tailPtr here to make sure it is still good:
#if 0
 -- There's a possibility for an infinite loop here with StableName based ptrEq.
 -- (And at one point I observed such an infinite loop.)
 -- But with one based on reallyUnsafePtrEquality# we should be ok.
	tail' <- readIORef tailPtr   -- ANDREAS: used atomicModifyIORef here
        if not (ptrEq tail tail') then loop newp 
         else case next of 
#else
	case next of 
#endif
          -- Here tail points (or pointed!) to the last node.  Try to link our new node.
          Null -> do (b,newtail) <- casIORef nextPtr next newp
		     if b then return tail
                          else loop newp
          Cons _ _ -> do 
             -- Someone has beat us by extending the tail.  Here we
             -- might have to do some community service by updating the tail ptr.
             casIORef tailPtr tail next 
             loop newp

-- Andreas's checked this invariant in several places
checkInvariant :: IO ()
checkInvariant = do 
  -- Check for: head /= tail, and head->next == NULL
  return ()

-- | Attempt to pop an element from the queue if one is available.
--   tryPop will return semi-promptly (depending on contention), but
--   will return 'Nothing' if the queue is empty.
tryPopR ::  LinkedQueue a -> IO (Maybe a)
-- FIXME -- this version
-- TODO -- add some kind of backoff.  This should probably at least
-- yield after a certain number of failures.
tryPopR (LQ headPtr tailPtr) = loop (0::Int) 
 where 
  loop !tries = do 
    head <- readIORef headPtr
    tail <- readIORef tailPtr
    case head of 
      Null -> error "tryPopR: LinkedQueue invariants broken.  Internal error."
      Cons _ next -> do
        next' <- readIORef next
        -- As with push, double-check our information is up-to-date. (head,tail,next consistent)
        head' <- readIORef headPtr -- ANDREAS: used atomicModifyIORef headPtr (\x -> (x,x))
        if not (ptrEq head head') then loop (tries+1) else do 
	  -- Is queue empty or tail falling behind?:
          if ptrEq head tail then do 
	    case next' of -- Is queue empty?
              Null -> return Nothing -- Queue is empty, couldn't dequeue
	      Cons _ _ -> do
  	        -- Tail is falling behind.  Try to advance it:
	        casIORef tailPtr tail next'
		loop (tries+1)
           
	   else do -- head /= tail
	      -- No need to deal with Tail.  Read value before CAS.
	      -- Otherwise, another dequeue might free the next node
	      case next' of 
--	        Null -> error "tryPop: Internal error.  Next should not be null if head/=tail."
	        Null -> loop (tries+1)
		Cons value _ -> do 
                  -- Try to swing Head to the next node
		  (b,_) <- casIORef headPtr head next' -- ANDREAS: FOUND CONDITION VIOLATED AFTER HERE
		  if b then return (Just value) -- Dequeue done; exit loop.
		       else loop (tries+1) -- ANDREAS: observed this loop being taken >1M times
          
-- | Create a new queue.
newQ :: IO (LinkedQueue a)
newQ = do 
  r <- newIORef Null
  let newp = Cons (error "LinkedQueue: Used uninitialized magic value.") r
  hd <- newIORef newp
  tl <- newIORef newp
  return (LQ hd tl)

-- | Is the queue currently empty?  Beware that this can be a highly transient state.
nullQ :: LinkedQueue a -> IO Bool
nullQ (LQ headPtr tailPtr) = do 
    head <- readIORef headPtr
    tail <- readIORef tailPtr
    return (ptrEq head tail)



--------------------------------------------------------------------------------
--   Instance(s) of abstract deque interface
--------------------------------------------------------------------------------

-- instance DequeClass (Deque T T S S Grow Safe) where 
instance C.DequeClass LinkedQueue where 
  newQ    = newQ
  nullQ   = nullQ
  pushL   = pushL
  tryPopR = tryPopR

--------------------------------------------------------------------------------
