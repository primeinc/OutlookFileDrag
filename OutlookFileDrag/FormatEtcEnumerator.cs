using System.Runtime.InteropServices.ComTypes;

namespace OutlookFileDrag
{
    class FormatEtcEnumerator : IEnumFORMATETC 
    {
        private FORMATETC[] formats;
        private int index = 0;

        public FormatEtcEnumerator(FORMATETC[] formats)
        {
            this.formats = formats;
        }

        public void Clone(out IEnumFORMATETC newEnum)
        {
            //Per IEnumFORMATETC::Clone, the new enumerator must carry the same enumeration state
            //(current position) as this one. index is private but accessible within the type.
            newEnum = new FormatEtcEnumerator(formats) { index = this.index };
        }

        public int Next(int celt, FORMATETC[] rgelt, int[] pceltFetched)
        {
            //Fetch number of requested formats
            int fetchCount = 0;
            for (int i = 0; i < celt; i++)
            {
                //If index is past end of formats, stop
                if (index > formats.Length - 1)
                    break;

                //Set format
                rgelt[i] = formats[index];
                fetchCount++;
                index++;
            }

            //Set number of formats fetched
            if (pceltFetched != null && pceltFetched.Length > 0)
                pceltFetched[0] = fetchCount;

            //Return S_OK if all requested formats were returned; otherwise, return S_FALSE
            return (fetchCount == celt ? NativeMethods.S_OK : NativeMethods.S_FALSE);
        }

        public int Reset()
        {
            //Set format index back to 0
            index = 0;
            return NativeMethods.S_OK;
        }

        public int Skip(int celt)
        {
            //Per IEnumFORMATETC::Skip, S_OK iff exactly celt items were skipped; otherwise S_FALSE
            //with the position left at the end. celt is a COM ULONG, so a value > int.MaxValue
            //marshals to a negative int; interpret it as unsigned and compute the target in 64-bit so
            //a huge/overflowing count cannot wrap the bound check and drive index negative (which
            //would make the next Next() read out of bounds). (The previous "Length - 1" bound also
            //wrongly reported S_FALSE when skipping exactly to the end.)
            long target = (long)index + (uint)celt;
            if (target > formats.Length)
            {
                index = formats.Length;
                return NativeMethods.S_FALSE;
            }

            index += celt;
            return NativeMethods.S_OK;
        }
    }
}
